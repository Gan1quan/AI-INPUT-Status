import Foundation
import SwiftUI
import UIKit

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
    @Published var tokenDraft = ""

    private var foregroundTask: Task<Void, Never>?
    private var statusRequestActive = false
    private var subscriptionRequestActive = false

    init() {
        snapshot = StatusEngine.loadCachedStatus()
        subscription = SubscriptionEngine.cached()
        notificationSettings = StatusEngine.loadNotificationSettings()
        monitors = StatusEngine.loadMonitors()
        Task { [weak self] in
            await self?.refresh(source: "启动")
        }
    }

    deinit { foregroundTask?.cancel() }

    func startForegroundLoop() {
        guard foregroundTask == nil else { return }
        foregroundTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = await self?.adaptiveDelay() ?? 60
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard UIApplication.shared.applicationState == .active else { continue }
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
        if states.contains(.offline) || states.contains(.unknown) { return 15 }
        if snapshot.gateway?.classification != .ok { return 30 }
        if (snapshot.gateway?.latencyMS ?? 0) >= 3000 { return 30 }
        return 60
    }

    func refresh(source: String = "手动刷新", forceSubscription: Bool = false) async {
        guard !statusRequestActive else { return }
        statusRequestActive = true
        isRefreshing = true
        lastError = nil
        defer {
            statusRequestActive = false
            isRefreshing = false
        }
        do {
            let result = try await StatusNetwork.loadStatus()
            snapshot = result.snapshot
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
        defer {
            subscriptionRequestActive = false
            subscriptionRefreshing = false
        }
        do {
            let value = try await SubscriptionEngine.fetch()
            subscription = value
            await processSubscriptionAlerts(value)
            await scheduleExpiryReminders(value)
        } catch {
            subscriptionError = error.localizedDescription
            subscription = SubscriptionEngine.displaySnapshot(SubscriptionEngine.cached(), error: subscriptionError)
        }
    }

    func saveToken() async {
        let value = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            subscriptionError = "请输入 Token"
            return
        }
        guard SecureStore.saveToken(value) else {
            subscriptionError = "Token 保存失败"
            return
        }
        tokenDraft = ""
        await refreshSubscription()
    }

    func pasteToken() {
        guard let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            subscriptionError = "剪贴板没有可用 Token"
            return
        }
        tokenDraft = value
        subscriptionError = nil
    }

    func removeToken() {
        SecureStore.removeToken()
        subscription = nil
        tokenDraft = ""
        subscriptionError = "已删除设备上的订阅 Token"
    }

    func requestNotificationPermission() async {
        _ = await NotificationEngine.requestAuthorization()
    }

    func updateNotificationSettings(_ value: NotificationSettings) {
        notificationSettings = value
        StatusEngine.saveNotificationSettings(value)
    }

    func updateMonitors(_ value: [CustomMonitor]) {
        monitors = Array(value.prefix(20))
        StatusEngine.saveMonitors(monitors)
    }

    func addMonitor() {
        guard monitors.count < 20 else { return }
        monitors.append(CustomMonitor(id: UUID().uuidString, enabled: false, label: "新监测目标", url: "", thresholdMS: 1500))
        StatusEngine.saveMonitors(monitors)
    }

    func deleteMonitor(at offsets: IndexSet) {
        monitors.remove(atOffsets: offsets)
        StatusEngine.saveMonitors(monitors)
    }

    var tokenConfigured: Bool { SubscriptionEngine.tokenConfigured }

    var pluginHealth: PluginHealth {
        guard let plugin = pluginStatus else { return .unavailable }
        guard plugin.lastSuccess > 0 else { return .starting }
        let age = Date().timeIntervalSince1970 - plugin.lastSuccess
        if age <= 300 { return .healthy }
        if age <= 900 { return .stale }
        return .failed
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
        guard let snapshot else { return "等待数据" }
        switch snapshot.source {
        case .daemon: return "DEB · live"
        case .publicAPI: return "API · live"
        case .cache: return "cache · \(StatusEngine.ageLabel(snapshot.age))"
        }
    }

    var gatewayLabel: String {
        guard let gateway = snapshot?.gateway, let latency = gateway.latencyMS else { return "api --" }
        return "api \(latency) ms"
    }

    var onlineCount: Int {
        snapshot?.services.filter { StatusEngine.serviceState($0) == .online }.count ?? 0
    }

    var shouldRefreshSubscription: Bool {
        guard tokenConfigured else { return false }
        guard let subscription = subscription ?? SubscriptionEngine.cached() else { return true }
        return subscription.age >= 30 * 60
    }

    private func processSubscriptionAlerts(_ value: SubscriptionSnapshot) async {
        guard notificationSettings.subscriptionQuotaEnabled, !value.fromCache, value.error == nil else { return }
        let thresholds = [70, 85, 95]
        let day = dayKey(Date())
        var sent = UserDefaults.standard.stringArray(forKey: "ai-input-quota-alerts") ?? []
        for plan in SubscriptionEngine.sortedPlans(value.plans).filter({ $0.isActive() }) {
            guard let threshold = thresholds.last(where: { plan.usagePercent >= Double($0) && $0 <= notificationSettings.subscriptionQuotaThreshold }) else { continue }
            let key = "\(day)|\(plan.id)|\(threshold)"
            guard !sent.contains(key) else { continue }
            await NotificationEngine.notifyQuota(plan, threshold: threshold, resetLabel: SubscriptionEngine.resetLabel())
            sent.append(key)
        }
        UserDefaults.standard.set(Array(sent.suffix(120)), forKey: "ai-input-quota-alerts")
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
