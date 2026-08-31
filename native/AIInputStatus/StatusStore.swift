import Foundation
import SwiftUI
import UIKit
import WidgetKit

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var pluginStatus: PluginStatus?
    @Published private(set) var subscription: SubscriptionSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var subscriptionRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var subscriptionError: String?
    @Published private(set) var refreshCount = 0
    @Published var historyRange: HistoryRange = .sixty
    @Published var notificationSettings: NotificationSettings
    @Published var monitors: [CustomMonitor]
    @Published var modelMonitors: [ModelMonitor]
    @Published var diagnosticFilter: DiagnosticFilter = .all
    @Published var serviceGrouping: ServiceGrouping = .model
    @Published var tokenDraft = ""
    @Published var sharePayload: SharePayload?
    @Published var lastActionMessage: String?

    private var foregroundTask: Task<Void, Never>?
    private var statusRequestActive = false
    private var subscriptionRequestActive = false

    init(autoRefresh: Bool = true) {
        snapshot = StatusEngine.loadCachedStatus()
        subscription = SubscriptionEngine.cached()
        notificationSettings = StatusEngine.loadNotificationSettings()
        monitors = StatusEngine.loadMonitors()
        modelMonitors = StatusEngine.loadModelMonitors()
        if autoRefresh {
            Task { [weak self] in await self?.refresh(source: "启动") }
        }
    }

    deinit { foregroundTask?.cancel() }

    func startForegroundLoop() {
        guard foregroundTask == nil else { return }
        foregroundTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = await self?.adaptiveDelay() ?? 60
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { continue }
                await self?.refresh(source: "前台自动")
            }
        }
    }

    func stopForegroundLoop() { foregroundTask?.cancel(); foregroundTask = nil }

    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            startForegroundLoop()
            Task { await refresh(source: "返回前台") }
        case .inactive, .background: stopForegroundLoop()
        @unknown default: break
        }
    }

    private func adaptiveDelay() -> TimeInterval {
        guard let snapshot else { return 30 }
        let states = snapshot.services.map { StatusEngine.serviceState($0) }
        if states.contains(where: { $0 != .online && $0 != .stale }) { return 15 }
        if snapshot.gateway?.classification != .ok || (snapshot.gateway?.latencyMS ?? 0) >= 3000 { return 30 }
        return 60
    }

    func refresh(source: String = "手动刷新", forceSubscription: Bool = false) async {
        guard !statusRequestActive else { return }
        statusRequestActive = true
        isRefreshing = true
        lastError = nil
        defer { statusRequestActive = false; isRefreshing = false }
        do {
            let result = try await StatusNetwork.loadStatus()
            snapshot = result.snapshot
            WidgetCenter.shared.reloadAllTimelines()
            if let plugin = result.plugin { pluginStatus = plugin }
            refreshCount += 1
            let changes = StatusEngine.updateEvents(result.snapshot, settings: notificationSettings)
            if notificationSettings.enabled {
                if !changes.opened.isEmpty { await NotificationEngine.notifyStatusOpened(changes.opened) }
                if notificationSettings.recoveryEnabled && !changes.recovered.isEmpty { await NotificationEngine.notifyStatusRecovered(changes.recovered) }
            }
            if forceSubscription || shouldRefreshSubscription { await refreshSubscription() }
        } catch {
            lastError = error.localizedDescription
            if snapshot == nil { snapshot = StatusEngine.loadCachedStatus() }
        }
    }

    func refreshSubscription() async {
        guard !subscriptionRequestActive else { return }
        guard SubscriptionEngine.tokenConfigured else {
            subscriptionError = "未配置订阅 Token"
            subscription = SubscriptionEngine.cached()
            return
        }
        subscriptionRequestActive = true
        subscriptionRefreshing = true
        subscriptionError = nil
        defer { subscriptionRequestActive = false; subscriptionRefreshing = false }
        do {
            let value = try await SubscriptionEngine.fetch()
            subscription = value
            WidgetCenter.shared.reloadAllTimelines()
            await processSubscriptionAlerts(value)
            await scheduleExpiryReminders(value)
        } catch {
            subscriptionError = error.localizedDescription
            subscription = SubscriptionEngine.displaySnapshot(SubscriptionEngine.cached(), error: subscriptionError)
        }
    }

    func saveToken() async {
        let value = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { subscriptionError = "请输入 Token"; return }
        guard SecureStore.saveToken(value) else { subscriptionError = "Token 保存失败"; return }
        tokenDraft = ""
        await refreshSubscription()
    }

    func pasteToken() {
        guard let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { subscriptionError = "剪贴板没有可用 Token"; return }
        tokenDraft = value
        subscriptionError = nil
    }

    func removeToken() {
        SecureStore.removeToken(); subscription = nil; tokenDraft = ""; subscriptionError = "已删除设备上的订阅 Token"
    }

    func requestNotificationPermission() async { _ = await NotificationEngine.requestAuthorization() }
    func updateNotificationSettings(_ value: NotificationSettings) { notificationSettings = value; StatusEngine.saveNotificationSettings(value) }
    func updateMonitors(_ value: [CustomMonitor]) { monitors = Array(value.prefix(20)); StatusEngine.saveMonitors(monitors) }
    func updateModelMonitors(_ value: [ModelMonitor]) { modelMonitors = Array(value.prefix(50)); StatusEngine.saveModelMonitors(modelMonitors) }
    func addModelMonitor() { guard modelMonitors.count < 50 else { return }; let id = UUID().uuidString; modelMonitors.append(ModelMonitor(id: id, model: "新模型", provider: "Input", account: "默认账号")); StatusEngine.saveModelMonitors(modelMonitors) }
    func deleteModelMonitors(at offsets: IndexSet) { modelMonitors.remove(atOffsets: offsets); StatusEngine.saveModelMonitors(modelMonitors) }

    func muteModel(_ model: ModelMonitor, hours: Int = 8) {
        guard let index = modelMonitors.firstIndex(where: { $0.id == model.id }) else { return }
        modelMonitors[index].mutedUntil = Calendar.current.date(byAdding: .hour, value: hours, to: Date())
        StatusEngine.saveModelMonitors(modelMonitors)
    }

    func maintenanceModel(_ model: ModelMonitor, hours: Int = 2) {
        guard let index = modelMonitors.firstIndex(where: { $0.id == model.id }) else { return }
        modelMonitors[index].maintenanceUntil = Calendar.current.date(byAdding: .hour, value: hours, to: Date())
        StatusEngine.saveModelMonitors(modelMonitors)
    }

    func clearMaintenance(_ model: ModelMonitor) {
        guard let index = modelMonitors.firstIndex(where: { $0.id == model.id }) else { return }
        modelMonitors[index].maintenanceUntil = nil
        StatusEngine.saveModelMonitors(modelMonitors)
    }

    func addMonitor() {
        guard monitors.count < 20 else { return }
        monitors.append(CustomMonitor(id: UUID().uuidString, enabled: false, label: "新监测目标", url: "", thresholdMS: 1500)); StatusEngine.saveMonitors(monitors)
    }
    func deleteMonitor(at offsets: IndexSet) { monitors.remove(atOffsets: offsets); StatusEngine.saveMonitors(monitors) }

    var tokenConfigured: Bool { SubscriptionEngine.tokenConfigured }
    var pluginHealth: PluginHealth {
        guard let plugin = pluginStatus else { return .unavailable }
        guard plugin.lastSuccess > 0 else { return .starting }
        let age = Date().timeIntervalSince1970 - plugin.lastSuccess
        return age <= 300 ? .healthy : age <= 900 ? .stale : .failed
    }
    var pluginHealthLabel: String { switch pluginHealth { case .healthy: return "运行中"; case .stale: return "数据已过期"; case .failed: return "后台异常"; case .starting: return "启动中"; case .unavailable: return "未连接" } }
    var sourceLabel: String { guard let snapshot else { return "等待数据" }; switch snapshot.source { case .daemon: return "DEB · live"; case .publicAPI: return "API · live"; case .cache: return "cache · \(StatusEngine.ageLabel(snapshot.age))" } }
    var gatewayLabel: String { snapshot?.gateway?.latencyMS.map { "状态 API \($0) ms" } ?? "状态 API --" }
    var onlineCount: Int { snapshot?.services.filter { StatusEngine.serviceState($0) == .online }.count ?? 0 }
    var shouldRefreshSubscription: Bool { guard tokenConfigured else { return false }; guard let subscription = subscription ?? SubscriptionEngine.cached() else { return true }; return subscription.age >= 30 * 60 }

    var visibleServices: [ServiceStatus] {
        guard let services = snapshot?.services else { return [] }
        return services.filter { service in
            let issue = ServiceIssue.from(service.last?.error)
            switch diagnosticFilter {
            case .all: return true
            case .healthy: return service.last?.ok == true
            case .configuration: return issue == .configuration
            case .authentication: return issue == .authentication
            case .quota: return issue == .quota
            case .rateLimit: return issue == .rateLimit
            case .timeout: return issue == .timeout
            case .network: return issue == .network
            case .server: return issue == .server
            case .client: return issue == .client
            }
        }
    }

    var groupedServices: [(String, [ServiceStatus])] {
        let services = visibleServices
        let grouping = serviceGrouping
        let configurations = Dictionary(uniqueKeysWithValues: modelMonitors.map { ($0.model, $0) })
        var groups: [String: [ServiceStatus]] = [:]
        for service in services {
            let key: String
            if let configuration = configurations[service.model] {
                switch grouping {
                case .model: key = service.model
                case .provider: key = configuration.provider.isEmpty ? "未标注供应商" : configuration.provider
                case .account: key = configuration.account.isEmpty ? "未标注账号" : configuration.account
                }
            } else {
                key = service.model
            }
            groups[key, default: []].append(service)
        }
        return groups.keys.sorted().compactMap { key in
            guard let values = groups[key] else { return nil }
            return (key, values.sorted { $0.model < $1.model })
        }
    }

    func backup(for service: ServiceStatus) -> ServiceStatus? {
        guard let services = snapshot?.services else { return nil }
        let candidates = services.filter { $0.id != service.id }
        let states = candidates.map { StatusEngine.serviceState($0) == .online ? true : false }
        let latencies = candidates.map { $0.last?.latencyMS }
        guard let index = RustCore.chooseBackup(states: states, latencies: latencies), candidates.indices.contains(index) else { return nil }
        return candidates[index]
    }

    func diagnosticReport(format: ExportFormat) -> String {
        guard let snapshot else { return "暂无状态数据" }
        let diagnostics = StatusEngine.diagnostics(snapshot, settings: notificationSettings)
        switch format {
        case .json:
            let serviceRows: [[String: Any]] = snapshot.services.map { service in
                let config = modelMonitors.first { $0.model == service.model }
                var row: [String: Any] = ["model": service.model, "state": stateText(StatusEngine.serviceState(service)), "latency_ms": service.last?.latencyMS ?? NSNull(), "error": service.last?.error ?? ""]
                row["provider"] = config?.provider ?? ""
                row["account"] = config?.account ?? ""
                row["issue"] = ServiceIssue.from(service.last?.error).title
                return row
            }
            let payload: [String: Any] = ["generated_at": ISO8601DateFormatter().string(from: snapshot.generatedAt), "fetched_at": ISO8601DateFormatter().string(from: snapshot.fetchedAt), "source": StatusEngine.dataTrustLabel(snapshot), "services": serviceRows, "diagnostics": diagnostics.map { ["title": $0.title, "detail": $0.detail, "technical_detail": $0.technicalDetail ?? ""] }]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        case .csv:
            let header = "model,provider,account,state,issue,latency_ms,error"
            let rows = snapshot.services.map { service -> String in
                let config = modelMonitors.first { $0.model == service.model }
                return [service.model, config?.provider ?? "", config?.account ?? "", stateText(StatusEngine.serviceState(service)), ServiceIssue.from(service.last?.error).title, service.last?.latencyMS.map(String.init) ?? "", service.last?.error ?? ""].map(csv).joined(separator: ",")
            }
            return ([header] + rows).joined(separator: "\n")
        }
    }

    func copyDiagnosticReport() {
        UIPasteboard.general.string = diagnosticReport(format: .json)
        lastActionMessage = "诊断报告已复制到剪贴板"
    }

    func export(format: ExportFormat) {
        let ext = format == .json ? "json" : "csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-input-status-\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            guard let data = diagnosticReport(format: format).data(using: .utf8) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            sharePayload = SharePayload(url: url)
            lastActionMessage = "已生成 \(ext.uppercased()) 报告"
        } catch {
            lastError = "导出失败：\(error.localizedDescription)"
        }
    }

    private func csv(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    private func processSubscriptionAlerts(_ value: SubscriptionSnapshot) async {
        guard notificationSettings.subscriptionQuotaEnabled, !value.fromCache, value.error == nil else { return }
        let thresholds = [70, 85, 95], day = dayKey(Date()); var sent = sharedDefaults.stringArray(forKey: "ai-input-quota-alerts") ?? []
        for plan in SubscriptionEngine.sortedPlans(value.plans).filter({ $0.isActive() }) { guard let threshold = thresholds.last(where: { plan.usagePercent >= Double($0) && $0 <= notificationSettings.subscriptionQuotaThreshold }) else { continue }; let key = "\(day)|\(plan.id)|\(threshold)"; guard !sent.contains(key) else { continue }; await NotificationEngine.notifyQuota(plan, threshold: threshold, resetLabel: SubscriptionEngine.resetLabel()); sent.append(key) }
        sharedDefaults.set(Array(sent.suffix(120)), forKey: "ai-input-quota-alerts")
    }
    private func scheduleExpiryReminders(_ value: SubscriptionSnapshot) async { guard notificationSettings.subscriptionExpiryEnabled else { return }; for plan in value.plans where plan.isActive() { for days in [30, 7, 1] { await NotificationEngine.scheduleExpiry(plan, daysBefore: days) } } }
    private func dayKey(_ date: Date) -> String { let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date) }
}

enum PluginHealth { case healthy, stale, failed, starting, unavailable }
