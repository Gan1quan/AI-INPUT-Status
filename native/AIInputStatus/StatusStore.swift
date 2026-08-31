import Foundation
import SwiftUI
import UIKit
import WidgetKit

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var pluginStatus: PluginStatus?
    @Published private(set) var backendLogs: [BackendLogEntry] = []
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
    @Published var serviceSort: ServiceSort = .issuesFirst
    @Published var searchText = ""
    @Published var widgetModelSelection: String
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
        widgetModelSelection = WidgetDataStore.selection
        publishWidgetData()
        if autoRefresh {
            Task { [weak self] in
                await self?.refresh(source: "启动", forceSubscription: false)
            }
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

    func stopForegroundLoop() {
        foregroundTask?.cancel()
        foregroundTask = nil
    }

    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            startForegroundLoop()
            Task { await refresh(source: "返回前台") }
        case .inactive, .background:
            stopForegroundLoop()
        @unknown default:
            break
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
        log(.status, event: "开始检测", detail: source)
        defer {
            statusRequestActive = false
            isRefreshing = false
        }

        do {
            let result = try await StatusNetwork.loadStatus()
            snapshot = result.snapshot
            StatusEngine.saveCachedStatus(result.snapshot)
            if let plugin = result.plugin {
                pluginStatus = plugin
                backendLogs = plugin.logs
                log(.backend, event: "后台状态已读取", detail: "成功 \(plugin.successes) / 失败 \(plugin.failures)")
            }
            refreshCount += 1
            let changes = StatusEngine.updateEvents(result.snapshot, settings: notificationSettings)
            if notificationSettings.enabled {
                if !changes.opened.isEmpty { await NotificationEngine.notifyStatusOpened(changes.opened) }
                if notificationSettings.recoveryEnabled && !changes.recovered.isEmpty {
                    await NotificationEngine.notifyStatusRecovered(changes.recovered)
                }
            }
            log(.status, event: "检测完成", detail: "\(onlineCount)/\(configuredCount) 个模型正常 · \(sourceLabel)")
            publishWidgetData()
            if forceSubscription || shouldRefreshSubscription { await refreshSubscription() }
            if source == "手动刷新" || source == "下拉刷新" || source == "立即刷新" {
                lastActionMessage = "状态已更新 · \(sourceLabel)"
            }
        } catch {
            let message = error.localizedDescription
            lastError = message
            log(.status, event: "检测失败", detail: message)
            if let old = snapshot {
                snapshot = StatusSnapshot(generatedAt: old.generatedAt, services: old.services,
                                          fetchedAt: old.fetchedAt, source: .cache,
                                          gateway: old.gateway, customMonitors: old.customMonitors,
                                          gatewayFromCache: true, lastError: message)
            }
            if snapshot == nil { snapshot = StatusEngine.loadCachedStatus() }
            publishWidgetData()
        }
    }

    func refreshModel(_ service: ServiceStatus) async {
        await refresh(source: "单模型刷新：\(service.model)", forceSubscription: false)
        if lastError == nil { lastActionMessage = "已重新检测 \(service.model)（状态接口按批次返回结果）" }
    }

    func refreshSubscription() async {
        guard !subscriptionRequestActive else { return }
        guard SubscriptionEngine.tokenConfigured else {
            subscriptionError = "未配置订阅 Token"
            subscription = SubscriptionEngine.cached()
            log(.subscription, event: "读取额度跳过", detail: "未配置 Token")
            publishWidgetData()
            return
        }
        subscriptionRequestActive = true
        subscriptionRefreshing = true
        subscriptionError = nil
        defer {
            subscriptionRequestActive = false
            subscriptionRefreshing = false
        }
        do {
            let value = try await SubscriptionEngine.fetch()
            subscription = value
            log(.subscription, event: "额度读取成功", detail: "\(value.plans.count) 个套餐")
            await processSubscriptionAlerts(value)
            await scheduleExpiryReminders(value)
            publishWidgetData()
            lastActionMessage = "额度已更新 · \(SubscriptionEngine.freshnessLabel(value))"
        } catch {
            subscriptionError = error.localizedDescription
            subscription = SubscriptionEngine.displaySnapshot(SubscriptionEngine.cached(), error: subscriptionError)
            log(.subscription, event: "额度读取失败", detail: subscriptionError ?? "未知错误")
            publishWidgetData()
        }
    }

    func saveToken() async {
        let value = SubscriptionEngine.normalizedToken(tokenDraft)
        guard !value.isEmpty else {
            subscriptionError = "请输入 Token"
            lastActionMessage = "请输入有效的订阅 Token"
            return
        }
        guard SecureStore.saveToken(value) else {
            subscriptionError = "Token 保存失败"
            lastActionMessage = "Token 保存失败，请重试"
            return
        }
        tokenDraft = ""
        log(.subscription, event: "Token 已保存", detail: "仅存储于本机 Keychain")
        lastActionMessage = "Token 已保存，正在读取额度"
        await refreshSubscription()
    }

    func pasteToken() {
        guard let value = UIPasteboard.general.string,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            subscriptionError = "剪贴板没有可用 Token"
            lastActionMessage = "剪贴板没有可用 Token"
            return
        }
        tokenDraft = value.trimmingCharacters(in: .whitespacesAndNewlines)
        subscriptionError = nil
        lastActionMessage = "Token 已从剪贴板填入，请点击保存并读取"
    }

    func removeToken() {
        SecureStore.removeToken()
        subscription = nil
        tokenDraft = ""
        subscriptionError = nil
        log(.subscription, event: "Token 已删除", detail: "已移除本机 Keychain 项")
        lastActionMessage = "已删除设备上的订阅 Token"
        publishWidgetData()
    }

    func requestNotificationPermission() async {
        let granted = await NotificationEngine.requestAuthorization()
        lastActionMessage = granted ? "通知权限已开启" : "通知权限未开启，请在系统设置中允许"
        log(.action, event: "请求通知权限", detail: granted ? "已授权" : "未授权")
    }

    func sendTestNotification() async {
        let granted = await NotificationEngine.requestAuthorization()
        guard granted else {
            lastActionMessage = "通知权限未开启，测试通知未发送"
            return
        }
        await NotificationEngine.notifyTest()
        lastActionMessage = "测试通知已发送"
        log(.action, event: "测试通知", detail: "已发送本地测试通知")
    }

    func updateNotificationSettings(_ value: NotificationSettings) {
        notificationSettings = value
        StatusEngine.saveNotificationSettings(value)
        log(.action, event: "通知设置更新", detail: "已保存")
    }

    func updateMonitors(_ value: [CustomMonitor]) {
        monitors = Array(value.prefix(20))
        StatusEngine.saveMonitors(monitors)
        log(.action, event: "自定义监测更新", detail: "\(monitors.count) 项")
    }

    func updateModelMonitors(_ value: [ModelMonitor]) {
        let normalized = Array(value.prefix(50)).map { monitor -> ModelMonitor in
            var copy = monitor
            copy.model = copy.model.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.provider = copy.provider.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.account = copy.account.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
        let named = normalized.filter { !$0.model.isEmpty }
        let duplicate = named.first { item in
            named.filter { $0.model == item.model }.count > 1
        }
        modelMonitors = normalized
        StatusEngine.saveModelMonitors(modelMonitors)
        if let duplicate {
            lastActionMessage = "模型名称重复：\(duplicate.model)"
        }
        if !modelMonitors.contains(where: { $0.model == widgetModelSelection && $0.enabled }) {
            widgetModelSelection = WidgetModelSelection.all.rawValue
            WidgetDataStore.setSelection(widgetModelSelection)
        }
        publishWidgetData()
    }

    func addModelMonitor() {
        guard modelMonitors.count < 50 else { return }
        let id = UUID().uuidString
        modelMonitors.append(ModelMonitor(id: id, model: "新模型", provider: "Input", account: "默认账号"))
        StatusEngine.saveModelMonitors(modelMonitors)
        publishWidgetData()
        lastActionMessage = "已添加模型，请填写模型名称后刷新"
    }

    func resetDefaultModels() {
        modelMonitors = ModelMonitor.defaults()
        StatusEngine.saveModelMonitors(modelMonitors)
        widgetModelSelection = WidgetModelSelection.all.rawValue
        WidgetDataStore.setSelection(widgetModelSelection)
        publishWidgetData()
        lastActionMessage = "已恢复默认模型列表"
    }

    func deleteModelMonitors(at offsets: IndexSet) {
        modelMonitors.remove(atOffsets: offsets)
        StatusEngine.saveModelMonitors(modelMonitors)
        if !modelMonitors.contains(where: { $0.model == widgetModelSelection }) {
            widgetModelSelection = WidgetModelSelection.all.rawValue
            WidgetDataStore.setSelection(widgetModelSelection)
        }
        publishWidgetData()
        lastActionMessage = "模型配置已删除"
    }

    func muteModel(_ model: ModelMonitor, hours: Int = 8) {
        guard let index = modelMonitors.firstIndex(where: { $0.id == model.id }) else { return }
        modelMonitors[index].mutedUntil = Calendar.current.date(byAdding: .hour, value: hours, to: Date())
        StatusEngine.saveModelMonitors(modelMonitors)
        lastActionMessage = "已忽略 \(model.model) \(hours) 小时"
    }

    func maintenanceModel(_ model: ModelMonitor, hours: Int = 2) {
        guard let index = modelMonitors.firstIndex(where: { $0.id == model.id }) else { return }
        modelMonitors[index].maintenanceUntil = Calendar.current.date(byAdding: .hour, value: hours, to: Date())
        StatusEngine.saveModelMonitors(modelMonitors)
        lastActionMessage = "已将 \(model.model) 标记为维护中"
    }

    func clearMaintenance(_ model: ModelMonitor) {
        guard let index = modelMonitors.firstIndex(where: { $0.id == model.id }) else { return }
        modelMonitors[index].maintenanceUntil = nil
        StatusEngine.saveModelMonitors(modelMonitors)
        lastActionMessage = "已取消 \(model.model) 的维护标记"
    }

    func addMonitor() {
        guard monitors.count < 20 else { return }
        monitors.append(CustomMonitor(id: UUID().uuidString, enabled: false, label: "新监测目标", url: "", thresholdMS: 1500))
        StatusEngine.saveMonitors(monitors)
        lastActionMessage = "已添加监测目标，请填写 HTTPS 地址"
    }

    func deleteMonitor(at offsets: IndexSet) {
        monitors.remove(atOffsets: offsets)
        StatusEngine.saveMonitors(monitors)
        lastActionMessage = "监测目标已删除"
    }

    // MARK: Backend administration

    func refreshBackendInfo() async {
        do {
            let value = try await StatusNetwork.loadDaemonStatus()
            pluginStatus = value.0
            backendLogs = value.0.logs
            lastActionMessage = "后台链路信息已更新"
            log(.backend, event: "读取后台信息", detail: "成功")
        } catch {
            lastActionMessage = "无法读取后台服务：\(error.localizedDescription)"
            log(.backend, event: "读取后台信息失败", detail: error.localizedDescription)
        }
    }

    func clearBackendCounters() async {
        do {
            let value = try await StatusNetwork.resetDaemonCounters()
            pluginStatus = value
            backendLogs = value.logs
            lastActionMessage = "后台请求次数已清零"
            log(.backend, event: "清理后台次数", detail: "计数已重置")
        } catch {
            let message = error.localizedDescription
            lastActionMessage = message.contains("不支持")
                ? "当前后台 DEB 不支持清零，请安装 v3.6.0 配套 DEB"
                : "清理后台次数失败：\(message)"
            log(.backend, event: "清理后台次数失败", detail: message)
        }
    }

    // MARK: Derived presentation data

    var tokenConfigured: Bool { SubscriptionEngine.tokenConfigured }
    var configuredModels: [ModelMonitor] {
        modelMonitors.filter { $0.enabled && !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var configuredCount: Int { configuredModels.count }
    var pluginHealth: PluginHealth {
        guard let plugin = pluginStatus else { return .unavailable }
        guard plugin.lastSuccess > 0 else { return .starting }
        let age = Date().timeIntervalSince1970 - plugin.lastSuccess
        return age <= 300 ? .healthy : age <= 900 ? .stale : .failed
    }
    var pluginHealthLabel: String {
        switch pluginHealth {
        case .healthy: return "运行中"
        case .stale: return "数据已过期"
        case .failed: return "后台异常"
        case .starting: return "启动中"
        case .unavailable: return "未连接"
        }
    }
    var sourceLabel: String {
        guard let snapshot else { return "等待首次检测" }
        switch snapshot.source {
        case .daemon: return "RootHide DEB · 实时"
        case .publicAPI: return "公共 API · 实时"
        case .cache: return "本地缓存 · \(StatusEngine.ageLabel(snapshot.age))"
        }
    }
    var gatewayLabel: String {
        guard let gateway = snapshot?.gateway else { return "状态 API --" }
        if let latency = gateway.latencyMS { return "状态 API \(latency) ms" }
        return "状态 API · \(gateway.detail)"
    }
    var onlineCount: Int {
        snapshot?.services.filter { StatusEngine.serviceState($0) == .online }.count ?? 0
    }
    var issueCount: Int { snapshot?.services.filter { let state = StatusEngine.serviceState($0); return state != .online && state != .waiting && state != .stale }.count ?? 0 }
    var waitingCount: Int { snapshot?.services.filter { StatusEngine.serviceState($0) == .waiting }.count ?? (snapshot == nil ? configuredCount : 0) }
    var staleCount: Int { snapshot?.services.filter { StatusEngine.serviceState($0) == .stale }.count ?? 0 }
    var shouldRefreshSubscription: Bool {
        guard tokenConfigured else { return false }
        guard let subscription = subscription ?? SubscriptionEngine.cached() else { return true }
        return subscription.age >= 30 * 60
    }
    var statusHeadline: String {
        guard configuredCount > 0 else { return "未配置模型" }
        guard snapshot != nil else { return "等待首次检测" }
        if waitingCount > 0 { return "\(waitingCount) 个模型等待检测" }
        if staleCount > 0 { return "\(staleCount) 个模型数据过期" }
        if issueCount > 0 { return "存在 \(issueCount) 个异常" }
        return "所有模型正常"
    }

    var visibleServices: [ServiceStatus] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let values = snapshot?.services ?? []
        return values.filter { service in
            let matchesSearch = query.isEmpty || service.model.lowercased().contains(query)
            return matchesSearch && StatusEngine.matches(diagnosticFilter, service: service)
        }.sorted(by: sortServices)
    }

    func filterCount(_ filter: DiagnosticFilter) -> Int {
        let values = snapshot?.services ?? []
        return values.filter { StatusEngine.matches(filter, service: $0) }.count
    }

    var groupedServices: [ServiceGroup] {
        let configurations = modelMonitors.reduce(into: [String: ModelMonitor]()) { result, model in
            result[model.model] = model
        }
        var groups: [String: [ServiceStatus]] = [:]
        for service in visibleServices {
            let configuration = configurations[service.model]
            let key: String
            switch serviceGrouping {
            case .model: key = service.model
            case .provider: key = configuration?.provider.isEmpty == false ? configuration!.provider : "未标注供应商"
            case .account: key = configuration?.account.isEmpty == false ? configuration!.account : "未标注账号"
            }
            groups[key, default: []].append(service)
        }
        return groups.map { key, values in
            ServiceGroup(name: key, services: values.sorted(by: sortServices))
        }.sorted { lhs, rhs in
            let leftRank = lhs.services.map { stateRank(StatusEngine.serviceState($0)) }.min() ?? 99
            let rightRank = rhs.services.map { stateRank(StatusEngine.serviceState($0)) }.min() ?? 99
            return leftRank == rightRank ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : leftRank < rightRank
        }
    }

    private func sortServices(_ lhs: ServiceStatus, _ rhs: ServiceStatus) -> Bool {
        switch serviceSort {
        case .issuesFirst:
            let left = stateRank(StatusEngine.serviceState(lhs))
            let right = stateRank(StatusEngine.serviceState(rhs))
            if left != right { return left < right }
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        case .latency:
            let left = lhs.last?.latencyMS ?? Int.max
            let right = rhs.last?.latencyMS ?? Int.max
            return left == right ? lhs.model < rhs.model : left < right
        case .availability:
            let left = lhs.uptimePercent ?? -1
            let right = rhs.uptimePercent ?? -1
            return left == right ? lhs.model < rhs.model : left > right
        case .name:
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
    }

    private func stateRank(_ state: ServiceState) -> Int {
        switch state {
        case .online: return 2
        case .waiting: return 3
        case .stale: return 1
        default: return 0
        }
    }

    func backup(for service: ServiceStatus) -> ServiceStatus? {
        guard let services = snapshot?.services else { return nil }
        let candidates = services.filter { $0.id != service.id }
        let states = candidates.map { StatusEngine.serviceState($0) == .online }
        let latencies = candidates.map { $0.last?.latencyMS }
        guard let index = RustCore.chooseBackup(states: states, latencies: latencies), candidates.indices.contains(index) else { return nil }
        return candidates[index]
    }

    // MARK: Reports and exports

    func diagnosticReport(format: ExportFormat) -> String {
        guard let snapshot else { return "暂无状态数据\n请点击立即刷新后再导出。" }
        let diagnostics = StatusEngine.diagnostics(snapshot, settings: notificationSettings)
        switch format {
        case .json:
            let serviceRows: [[String: Any]] = snapshot.services.map { service in
                let config = modelMonitors.first { $0.model == service.model }
                let summary = StatusEngine.historySummary(service, range: historyRange)
                var row: [String: Any] = [
                    "model": service.model,
                    "state": stateText(StatusEngine.serviceState(service)),
                    "latency_ms": service.last?.latencyMS ?? NSNull(),
                    "uptime_percent": service.uptimePercent ?? NSNull(),
                    "observed": summary.observed,
                    "missing": summary.missing,
                    "error": service.last?.error ?? ""
                ]
                row["provider"] = config?.provider ?? ""
                row["account"] = config?.account ?? ""
                row["issue"] = ServiceIssue.from(service.last?.error).title
                return row
            }
            let payload: [String: Any] = [
                "app_version": "3.6.0",
                "generated_at": ISO8601DateFormatter().string(from: snapshot.generatedAt),
                "fetched_at": ISO8601DateFormatter().string(from: snapshot.fetchedAt),
                "source": StatusEngine.dataTrustLabel(snapshot),
                "configured_count": configuredCount,
                "online_count": onlineCount,
                "services": serviceRows,
                "diagnostics": diagnostics.map { ["title": $0.title, "detail": $0.detail, "technical_detail": $0.technicalDetail ?? ""] },
                "backend": pluginStatus.map { ["attempts": $0.attempts, "successes": $0.successes, "failures": $0.failures] } ?? [:]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        case .csv:
            let header = "model,provider,account,state,issue,latency_ms,uptime_percent,observed,missing,error"
            let rows = snapshot.services.map { service -> String in
                let config = modelMonitors.first { $0.model == service.model }
                let summary = StatusEngine.historySummary(service, range: historyRange)
                return [service.model, config?.provider ?? "", config?.account ?? "", stateText(StatusEngine.serviceState(service)),
                        ServiceIssue.from(service.last?.error).title, service.last?.latencyMS.map(String.init) ?? "",
                        service.uptimePercent.map { String(format: "%.1f", $0) } ?? "", "\(summary.observed)", "\(summary.missing)", service.last?.error ?? ""].map(csv).joined(separator: ",")
            }
            return ([header] + rows).joined(separator: "\n")
        }
    }

    func diagnosticReport(for service: ServiceStatus) -> String {
        let state = StatusEngine.serviceState(service)
        let summary = StatusEngine.historySummary(service, range: historyRange)
        let stats = StatusEngine.latencyStats(service, range: historyRange)
        let config = modelMonitors.first { $0.model == service.model }
        return [
            "AI INPUT Status 3.6.0",
            "模型：\(service.model)",
            "状态：\(stateText(state))",
            "供应商：\(config?.provider ?? "未标注")",
            "账号：\(config?.account ?? "未标注")",
            "当前延迟：\(service.last?.latencyMS.map { "\($0) ms" } ?? "--")",
            "\(historyRange.fullLabel)：成功 \(summary.succeeded) · 失败 \(summary.failed) · 未采样 \(summary.missing)",
            "延迟：p50 \(stats.median.map(String.init) ?? "--") · p95 \(stats.p95.map(String.init) ?? "--") · 最大 \(stats.maximum.map(String.init) ?? "--") ms",
            "最后探测：\(clock(service.last?.timestamp))",
            "错误：\(service.last?.error ?? "无")"
        ].joined(separator: "\n")
    }

    func copyDiagnosticReport() {
        UIPasteboard.general.string = diagnosticReport(format: .json)
        lastActionMessage = "诊断报告已复制到剪贴板"
        log(.action, event: "复制诊断报告", detail: "JSON")
    }

    func copyDiagnosticReport(for service: ServiceStatus) {
        UIPasteboard.general.string = diagnosticReport(for: service)
        lastActionMessage = "\(service.model) 诊断已复制到剪贴板"
        log(.action, event: "复制模型诊断", detail: service.model)
    }

    func export(format: ExportFormat) {
        let ext = format == .json ? "json" : "csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-input-status-\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            guard let data = diagnosticReport(format: format).data(using: .utf8) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            sharePayload = SharePayload(url: url)
            lastActionMessage = "已生成 \(ext.uppercased()) 报告"
            log(.action, event: "导出诊断报告", detail: ext.uppercased())
        } catch {
            lastError = "导出失败：\(error.localizedDescription)"
        }
    }

    func exportLogs(categories: Set<AppLogCategory>, range: AppLogRange, format: AppLogFormat) async {
        guard !categories.isEmpty else {
            lastActionMessage = "请至少选择一种日志类型"
            return
        }
        if categories.contains(.backend), let value = try? await StatusNetwork.loadDaemonLogs() {
            backendLogs = value
        }
        let cutoff = range.interval.map { Date().addingTimeInterval(-$0) }
        var rows: [LogExportRow] = []
        let appRows = AppLogStore.load().filter { entry in
            categories.contains(entry.category) && (cutoff == nil || entry.date >= cutoff!)
        }
        rows.append(contentsOf: appRows.map { LogExportRow(id: $0.id, date: $0.date, category: $0.category.label, event: $0.event, detail: $0.detail) })
        if categories.contains(.status) {
            rows.append(contentsOf: StatusEngine.loadEvents().filter { cutoff == nil || $0.date >= cutoff! }.map {
                LogExportRow(id: $0.id, date: $0.date, category: "异常事件", event: $0.phase == .opened ? "异常" : "恢复", detail: "\($0.target) · \($0.detail)")
            })
        }
        if categories.contains(.backend) {
            rows.append(contentsOf: backendLogs.filter { cutoff == nil || $0.date >= cutoff! }.map {
                LogExportRow(id: "backend-\($0.id)", date: $0.date, category: "后台链路", event: $0.event, detail: "\($0.level) · \($0.detail)")
            })
            if backendLogs.isEmpty, let plugin = pluginStatus {
                rows.append(LogExportRow(id: "backend-summary", date: Date(), category: "后台链路", event: "计数摘要", detail: "请求 \(plugin.attempts) · 成功 \(plugin.successes) · 失败 \(plugin.failures)"))
            }
        }
        if categories.contains(.subscription), let value = subscription {
            let summary = SubscriptionEngine.summary(value.plans)
            rows.append(LogExportRow(id: "subscription-summary", date: value.fetchedAt, category: "额度订阅", event: "额度摘要", detail: "剩余 \(money(summary.totalRemainingUSD)) / \(money(summary.totalLimitUSD)) · \(value.plans.count) 个套餐"))
        }
        rows.sort { $0.date > $1.date }
        do {
            let content: String
            switch format {
            case .text:
                content = rows.isEmpty ? "暂无符合条件的日志" : rows.map { "[\($0.date.formatted())] [\($0.category)] \($0.event) · \($0.detail)" }.joined(separator: "\n")
            case .json:
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                content = String(data: try encoder.encode(rows), encoding: .utf8) ?? "[]"
            case .csv:
                content = (["timestamp,category,event,detail"] + rows.map { [ISO8601DateFormatter().string(from: $0.date), $0.category, $0.event, $0.detail].map(csv).joined(separator: ",") }).joined(separator: "\n")
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-input-logs-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)")
            try Data(content.utf8).write(to: url, options: .atomic)
            sharePayload = SharePayload(url: url)
            lastActionMessage = "已导出 \(rows.count) 条日志"
            log(.action, event: "导出日志", detail: "\(rows.count) 条 · \(format.label)")
        } catch {
            lastActionMessage = "日志导出失败：\(error.localizedDescription)"
        }
    }

    private func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: Widget bridge

    func setWidgetModelSelection(_ value: String) {
        let valid = value == WidgetModelSelection.all.rawValue || configuredModels.contains(where: { $0.model == value })
        widgetModelSelection = valid ? value : WidgetModelSelection.all.rawValue
        WidgetDataStore.setSelection(widgetModelSelection)
        publishWidgetData()
        lastActionMessage = widgetModelSelection == WidgetModelSelection.all.rawValue ? "Widget 将显示全部模型" : "Widget 将显示 \(widgetModelSelection)"
    }

    private func publishWidgetData() {
        let configs = configuredModels
        let services: [WidgetServiceData] = configs.map { config in
            guard let service = snapshot?.services.first(where: { $0.model == config.model }) else {
                return WidgetServiceData(model: config.model, state: "waiting", stateLabel: "待检测", latencyMS: nil,
                                         uptimePercent: nil, windowSuccessRate: nil, observed: 0, window: historyRange.rawValue, error: nil)
            }
            let state = StatusEngine.serviceState(service)
            let summary = StatusEngine.historySummary(service, range: historyRange)
            return WidgetServiceData(model: service.model, state: widgetStateKey(state), stateLabel: stateText(state),
                                     latencyMS: service.last?.latencyMS, uptimePercent: service.uptimePercent,
                                     windowSuccessRate: summary.successRate, observed: summary.observed,
                                     window: historyRange.rawValue, error: service.last?.error)
        }
        let quota: WidgetQuotaData?
        if let value = subscription {
            let active = value.plans.filter { $0.isActive() }
            let summary = SubscriptionEngine.summary(active)
            let health = SubscriptionEngine.health(value, tokenConfigured: tokenConfigured, error: subscriptionError)
            let state = health == .ready ? "ready" : health == .stale || health == .cached ? "stale" : "error"
            quota = WidgetQuotaData(state: state, stateLabel: SubscriptionEngine.healthLabel(health),
                                    remainingUSD: active.isEmpty ? nil : summary.totalRemainingUSD,
                                    limitUSD: active.isEmpty ? nil : summary.totalLimitUSD,
                                    usageUSD: active.isEmpty ? nil : summary.totalUsageUSD,
                                    planCount: active.count, fetchedAt: value.fetchedAt)
        } else {
            quota = WidgetQuotaData(state: tokenConfigured ? "waiting" : "unconfigured",
                                    stateLabel: tokenConfigured ? "等待额度数据" : "未配置额度 Token",
                                    remainingUSD: nil, limitUSD: nil, usageUSD: nil, planCount: 0, fetchedAt: nil)
        }
        let backend = pluginStatus.map {
            WidgetBackendData(state: pluginHealth == .healthy ? "ready" : "stale",
                              stateLabel: pluginHealthLabel, attempts: $0.attempts,
                              successes: $0.successes, failures: $0.failures, lastSuccess: $0.lastSuccessDate)
        }
        let dataState: String
        let dataStateLabel: String
        let source: String
        let sourceText: String
        if let value = snapshot {
            dataState = value.age > StatusEngine.cacheExpiry ? "stale" : "live"
            dataStateLabel = value.age > StatusEngine.cacheExpiry ? "数据已过期" : "状态已同步"
            source = value.source.rawValue
            sourceText = sourceLabel
        } else {
            dataState = "waiting"
            dataStateLabel = "等待数据"
            source = "waiting"
            sourceText = "等待首次检测"
        }
        let snapshot = WidgetDataSnapshot(version: WidgetDataSnapshot.currentVersion,
                                          configuredCount: configs.count,
                                       source: source,
                                       sourceLabel: sourceText,
                                       dataState: dataState,
                                       dataStateLabel: dataStateLabel,
                                       updatedAt: snapshot?.fetchedAt ?? Date(),
                                       generatedAt: snapshot?.generatedAt,
                                       services: services,
                                       quota: quota,
                                       backend: backend,
                                       message: snapshot?.lastError ?? (configs.isEmpty ? "请打开 App 设置模型" : nil))
        WidgetDataStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func widgetStateKey(_ state: ServiceState) -> String {
        switch state {
        case .online: return "online"
        case .waiting: return "waiting"
        case .notConfigured: return "notConfigured"
        case .stale: return "stale"
        default: return "error"
        }
    }

    private func log(_ category: AppLogCategory, event: String, detail: String) {
        AppLogStore.append(category: category, event: event, detail: detail)
    }

    private func processSubscriptionAlerts(_ value: SubscriptionSnapshot) async {
        guard notificationSettings.subscriptionQuotaEnabled, !value.fromCache, value.error == nil else { return }
        let thresholds = [70, 85, 95]
        let day = dayKey(Date())
        var sent = sharedDefaults.stringArray(forKey: "ai-input-quota-alerts") ?? []
        for plan in SubscriptionEngine.sortedPlans(value.plans).filter({ $0.isActive() }) {
            guard let threshold = thresholds.last(where: { plan.usagePercent >= Double($0) && $0 <= notificationSettings.subscriptionQuotaThreshold }) else { continue }
            let key = "\(day)|\(plan.id)|\(threshold)"
            guard !sent.contains(key) else { continue }
            await NotificationEngine.notifyQuota(plan, threshold: threshold, resetLabel: SubscriptionEngine.resetLabel())
            sent.append(key)
        }
        sharedDefaults.set(Array(sent.suffix(120)), forKey: "ai-input-quota-alerts")
    }

    private func scheduleExpiryReminders(_ value: SubscriptionSnapshot) async {
        guard notificationSettings.subscriptionExpiryEnabled else { return }
        for plan in value.plans where plan.isActive() {
            for days in [30, 7, 1] { await NotificationEngine.scheduleExpiry(plan, daysBefore: days) }
        }
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum PluginHealth { case healthy, stale, failed, starting, unavailable }
