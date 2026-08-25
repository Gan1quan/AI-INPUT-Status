import Foundation
import SwiftUI
import UIKit

@main
struct AIInputStatusApp: App {
    @UIApplicationDelegateAdaptor(AIInputStatusAppDelegate.self) private var appDelegate
    @StateObject private var store = StatusStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct Probe: Codable, Identifiable, Hashable {
    let timestamp: Date
    let ok: Bool
    let latencyMS: Int?
    let error: String?
    var id: TimeInterval { timestamp.timeIntervalSince1970 }
    enum CodingKeys: String, CodingKey { case timestamp = "ts", ok, latencyMS = "latency_ms", error }
}

struct ServiceStatus: Codable, Identifiable, Hashable {
    var id: String { model }
    let model: String
    let uptimePercent: Double?
    let last: Probe?
    let history: [Probe]
    enum CodingKeys: String, CodingKey { case model, uptimePercent = "uptime_pct", last, history }
}

struct Snapshot: Codable, Hashable {
    let generatedAt: Date
    let services: [ServiceStatus]
    enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", services }
}

struct CachedStatus: Codable {
    let snapshot: Snapshot
    let fetchedAt: Date
    let lastError: String?
    var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }
    var isStale: Bool { age > 240 }
}

struct RefreshDiagnostics: Codable {
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var lastError: String?
    var totalAttempts: Int = 0
    var successfulAttempts: Int = 0
    var failedAttempts: Int = 0
    var backgroundFetches: Int = 0
    var backgroundSuccesses: Int = 0
    var backgroundFailures: Int = 0
    var recentIntervals: [TimeInterval] = []
    var lastExecutionSource: String = "启动"

    var lastInterval: TimeInterval? { recentIntervals.last }
    var maxInterval: TimeInterval? { recentIntervals.max() }

    enum CodingKeys: String, CodingKey {
        case lastAttemptAt, lastSuccessAt, lastFailureAt, lastError
        case totalAttempts, successfulAttempts, failedAttempts
        case backgroundFetches, backgroundSuccesses, backgroundFailures
        case recentIntervals, lastExecutionSource
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastFailureAt = try container.decodeIfPresent(Date.self, forKey: .lastFailureAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        totalAttempts = try container.decodeIfPresent(Int.self, forKey: .totalAttempts) ?? 0
        successfulAttempts = try container.decodeIfPresent(Int.self, forKey: .successfulAttempts) ?? 0
        failedAttempts = try container.decodeIfPresent(Int.self, forKey: .failedAttempts) ?? 0
        backgroundFetches = try container.decodeIfPresent(Int.self, forKey: .backgroundFetches) ?? 0
        backgroundSuccesses = try container.decodeIfPresent(Int.self, forKey: .backgroundSuccesses) ?? 0
        backgroundFailures = try container.decodeIfPresent(Int.self, forKey: .backgroundFailures) ?? 0
        recentIntervals = try container.decodeIfPresent([TimeInterval].self, forKey: .recentIntervals) ?? []
        lastExecutionSource = try container.decodeIfPresent(String.self, forKey: .lastExecutionSource) ?? "启动"
    }
}

struct PluginStatus: Codable {
    let version: Int
    let daemon: String
    let attempts: Int
    let successes: Int
    let failures: Int
    let lastAttempt: TimeInterval
    let lastSuccess: TimeInterval
    let lastFailure: TimeInterval
    let lastInterval: TimeInterval
    let lastError: String?
    let payload: String?
    enum CodingKeys: String, CodingKey {
        case version, daemon, attempts, successes, failures, payload
        case lastAttempt = "last_attempt", lastSuccess = "last_success", lastFailure = "last_failure"
        case lastInterval = "last_interval", lastError = "last_error"
    }
}

struct StatusRequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Observation: Codable, Identifiable, Hashable {
    let timestamp: Date
    let model: String
    let ok: Bool
    let confirmationTime: Date
    var id: String { "\(model)-\(timestamp.timeIntervalSince1970)" }
}

struct DailyStatistics {
    let normal: TimeInterval
    let abnormal: TimeInterval
    let incidents: Int
    var availability: Double {
        let observed = normal + abnormal
        return observed > 0 ? normal / observed * 100 : 0
    }
}

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var cached: CachedStatus?
    @Published private(set) var observations: [Observation] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshCount = 0
    @Published private(set) var diagnostics: RefreshDiagnostics
    @Published private(set) var lastRefreshError: String?
    @Published private(set) var pluginStatus: PluginStatus?
    @Published private(set) var pluginCheckedAt: Date?
    private let endpoint = URL(string: "https://status.input.im/api/status")!
    private let daemonStatusURL = URL(string: "http://127.0.0.1:17891/status")!
    private let daemonRefreshURL = URL(string: "http://127.0.0.1:17891/refresh")!
    private let cacheKey = "ai-input-status-cache.v3"
    private let legacyCacheKey = "ai-input-status-cache.v2"
    private let observationKey = "ai-input-status-observations.v1"
    private let diagnosticsKey = "ai-input-status-diagnostics.v1"
    private var refreshTask: Task<Void, Never>?
    private var activeRequest = false

    init(autoRefresh: Bool = true) {
        diagnostics = (UserDefaults.standard.data(forKey: diagnosticsKey).flatMap { try? JSONDecoder().decode(RefreshDiagnostics.self, from: $0) }) ?? RefreshDiagnostics()
        loadCache()
        loadObservations()
        lastRefreshError = cached?.lastError
        Task { await loadPluginStatus() }
        guard autoRefresh else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    deinit { refreshTask?.cancel() }

    func loadPluginStatus() async {
        do {
            var request = URLRequest(url: daemonStatusURL)
            request.timeoutInterval = 1.5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            pluginStatus = try JSONDecoder().decode(PluginStatus.self, from: data)
        } catch {
            pluginStatus = nil
        }
        pluginCheckedAt = Date()
    }

    private func requestDaemonPayload(refresh: Bool) async throws -> Data {
        var request = URLRequest(url: refresh ? daemonRefreshURL : daemonStatusURL)
        request.timeoutInterval = refresh ? 14 : 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StatusRequestError(message: "后台服务无有效响应") }
        guard (200..<300).contains(http.statusCode) else { throw StatusRequestError(message: "后台服务 HTTP \(http.statusCode)") }
        let status = try JSONDecoder().decode(PluginStatus.self, from: data)
        pluginStatus = status
        pluginCheckedAt = Date()
        guard let payload = status.payload, let payloadData = payload.data(using: .utf8) else {
            throw StatusRequestError(message: "后台服务尚未生成状态数据")
        }
        return payloadData
    }

    private func requestPublicPayload() async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StatusRequestError(message: "未收到有效 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else { throw StatusRequestError(message: "HTTP \(http.statusCode)") }
        return data
    }

    func refresh(source: String = "前台") async -> Bool {
        while activeRequest {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if Task.isCancelled { return false }
        activeRequest = true
        isRefreshing = true
        let attemptAt = Date()
        let isBackground = source.contains("后台")
        diagnostics.totalAttempts += 1
        if isBackground { diagnostics.backgroundFetches += 1 }
        if let previous = diagnostics.lastAttemptAt {
            let interval = max(0, attemptAt.timeIntervalSince(previous))
            diagnostics.recentIntervals = Array((diagnostics.recentIntervals + [interval]).suffix(48))
        }
        diagnostics.lastAttemptAt = attemptAt
        diagnostics.lastExecutionSource = source
        saveDiagnostics()
        defer {
            activeRequest = false
            isRefreshing = false
        }
        do {
            let data: Data
            do {
                // The DEB owns polling and SpringBoard wakes it; the IPA only consumes its result.
                data = try await requestDaemonPayload(refresh: true)
            } catch {
                // Keep the app useful when the tweak is not installed or is being restarted.
                data = try await requestPublicPayload()
            }
            let fetchedAt = Date()
            let value = CachedStatus(snapshot: try decodeSnapshot(data), fetchedAt: fetchedAt, lastError: nil)
            cached = value
            recordObservations(for: value.snapshot, at: fetchedAt)
            refreshCount += 1
            lastRefreshError = nil
            diagnostics.lastSuccessAt = fetchedAt
            diagnostics.lastError = nil
            diagnostics.successfulAttempts += 1
            if isBackground { diagnostics.backgroundSuccesses += 1 }
            saveCache(value)
            saveDiagnostics()
            return true
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return false }
            let message = readableError(error)
            lastRefreshError = message
            diagnostics.lastFailureAt = Date()
            diagnostics.lastError = message
            diagnostics.failedAttempts += 1
            if isBackground { diagnostics.backgroundFailures += 1 }
            if let old = cached {
                let failed = CachedStatus(snapshot: old.snapshot, fetchedAt: old.fetchedAt, lastError: message)
                cached = failed
                saveCache(failed)
            }
            saveDiagnostics()
            return false
        }
    }

    func refresh() async { _ = await refresh(source: "前台") }

    func handleScene(_ phase: ScenePhase) {
        if phase == .active {
            Task { await loadPluginStatus(); await refresh(source: "返回前台") }
        }
    }

    private func readableError(_ error: Error) -> String {
        if let requestError = error as? StatusRequestError { return requestError.message }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时"
            case .notConnectedToInternet: return "没有网络连接"
            case .cannotFindHost, .cannotConnectToHost: return "无法连接状态服务"
            case .cancelled: return "请求已取消"
            default: return "网络错误（\(urlError.code.rawValue)）"
            }
        }
        if error is DecodingError { return "状态数据格式错误" }
        return error.localizedDescription
    }

    private func saveDiagnostics() {
        if let data = try? JSONEncoder().encode(diagnostics) { UserDefaults.standard.set(data, forKey: diagnosticsKey) }
    }

    func statistics(for service: ServiceStatus) -> DailyStatistics {
        let start = Calendar.current.startOfDay(for: Date())
        let entries = observations.filter { $0.model == service.model && $0.timestamp >= start }.sorted { $0.timestamp < $1.timestamp }
        guard let first = entries.first else { return DailyStatistics(normal: 0, abnormal: 0, incidents: 0) }
        var normal: TimeInterval = 0
        var abnormal: TimeInterval = 0
        var incidents = first.ok ? 0 : 1
        for index in entries.indices {
            let current = entries[index]
            let end = index + 1 < entries.count ? entries[index + 1].timestamp : Date()
            let interval = max(0, end.timeIntervalSince(current.timestamp))
            if current.ok { normal += interval } else { abnormal += interval }
            if index + 1 < entries.count, current.ok && !entries[index + 1].ok { incidents += 1 }
        }
        return DailyStatistics(normal: normal, abnormal: abnormal, incidents: incidents)
    }

    func stateStartedAt(for service: ServiceStatus) -> Date? {
        let entries = observations.filter { $0.model == service.model }.sorted { $0.timestamp < $1.timestamp }
        guard let latest = entries.last else { return service.last?.timestamp }
        for index in entries.indices.reversed() where index + 1 < entries.count && entries[index].ok != latest.ok {
            return entries[index + 1].timestamp
        }
        return entries.first?.timestamp
    }

    static func performBackgroundRefresh(source: String = "系统后台 fetch") async -> Bool {
        let store = await MainActor.run { StatusStore(autoRefresh: false) }
        return await store.refresh(source: source)
    }

    private func decodeSnapshot(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let raw = try decoder.decode(Snapshot.self, from: data)
        let models = ["gpt-5.6-sol", "gpt-5.6-terra"]
        let services = models.map { model in
            raw.services.first(where: { $0.model == model }) ?? ServiceStatus(model: model, uptimePercent: nil, last: nil, history: [])
        }
        return Snapshot(generatedAt: raw.generatedAt, services: services)
    }

    private func loadCache() {
        let data = UserDefaults.standard.data(forKey: cacheKey) ?? UserDefaults.standard.data(forKey: legacyCacheKey)
        guard let data, let value = try? JSONDecoder().decode(CachedStatus.self, from: data) else { return }
        cached = value
    }

    private func loadObservations() {
        guard let data = UserDefaults.standard.data(forKey: observationKey) else { return }
        observations = (try? JSONDecoder().decode([Observation].self, from: data)) ?? []
    }

    private func recordObservations(for snapshot: Snapshot, at date: Date) {
        let newValues = snapshot.services.compactMap { service -> Observation? in
            guard let last = service.last else { return nil }
            return Observation(timestamp: date, model: service.model, ok: last.ok, confirmationTime: last.timestamp)
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -8, to: date) ?? date
        let existingKeys = Set(observations.map { "\($0.model)|\($0.confirmationTime.timeIntervalSince1970)|\($0.ok)" })
        let additions = newValues.filter {
            !existingKeys.contains("\($0.model)|\($0.confirmationTime.timeIntervalSince1970)|\($0.ok)")
        }
        observations = (observations + additions).filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
        guard let data = try? JSONEncoder().encode(observations) else { return }
        UserDefaults.standard.set(data, forKey: observationKey)
    }

    private func saveCache(_ value: CachedStatus) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: StatusStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    terminalHeader
                    Rectangle().fill(TerminalPalette.rule).frame(height: 1).padding(.vertical, 16)
                    if let cached = store.cached {
                        terminalBody(cached)
                    } else if let error = store.lastRefreshError {
                        refreshFailureView(error)
                    } else {
                        Text(store.isRefreshing ? "正在连接 status.input.im ..." : "等待首次请求 ...")
                            .font(TerminalPalette.body)
                            .foregroundColor(TerminalPalette.dim)
                            .padding(.top, 80)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .background(TerminalPalette.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await store.refresh(source: "下拉刷新") }
            .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(store) }
        }
        .navigationViewStyle(.stack)
        .onChange(of: scenePhase) { store.handleScene($0) }
    }

    private func refreshFailureView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("无法取得最新状态")
                .font(TerminalPalette.model)
                .foregroundColor(TerminalPalette.red)
            Text(error)
                .font(TerminalPalette.body)
                .foregroundColor(TerminalPalette.dim)
            Text("下拉或点击右上角重试")
                .font(TerminalPalette.meta)
                .foregroundColor(TerminalPalette.dim)
            Button { Task { await store.refresh(source: "手动重试") } } label: {
                Label("重新请求", systemImage: "arrow.clockwise")
                    .font(TerminalPalette.body)
                    .foregroundColor(TerminalPalette.green)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
        }
        .padding(.top, 80)
    }

    private var terminalHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("AI INPUT")
                .font(TerminalPalette.brand)
                .foregroundColor(TerminalPalette.green)
            Spacer()
            Text(store.isRefreshing ? "syncing" : "api \(apiLabel)")
                .font(TerminalPalette.meta)
                .foregroundColor(apiColor)
            Button { Task { await store.refresh(source: "手动刷新") } } label: {
                Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(TerminalPalette.dim)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            Button { showingSettings = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(TerminalPalette.dim)
            }
            .buttonStyle(.plain)
        }
    }

    private func terminalBody(_ cached: CachedStatus) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(cached.snapshot.services) { service in
                TerminalService(service: service, cached: cached, statistics: store.statistics(for: service), stateStartedAt: store.stateStartedAt(for: service))
            }
            Rectangle().fill(TerminalPalette.rule).frame(height: 1).padding(.top, 2)
            HStack(alignment: .firstTextBaseline) {
                Text(store.isRefreshing ? "正在请求最新状态" : "数据 \(clock(cached.snapshot.generatedAt))")
                Spacer()
                Text("成功 \(clock(cached.fetchedAt)) · \(cached.ageText)")
            }
            .font(TerminalPalette.footer)
            .foregroundColor(cached.lastError == nil ? TerminalPalette.dim : TerminalPalette.amber)
            if let error = cached.lastError {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近请求未完成，以下为缓存状态")
                    Text(error)
                }
                .font(TerminalPalette.footer)
                .foregroundColor(TerminalPalette.amber)
            }
        }
    }

    private var apiLabel: String {
        guard let cached = store.cached else { return "--" }
        return cached.lastError == nil ? "ok" : "--"
    }

    private var apiColor: Color {
        guard let cached = store.cached else { return TerminalPalette.dim }
        return cached.lastError == nil ? TerminalPalette.green : TerminalPalette.amber
    }

    private func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

extension CachedStatus {
    var ageText: String {
        let seconds = max(0, Int(age))
        if seconds < 60 { return "\(seconds) 秒前" }
        return "\(seconds / 60) 分钟前"
    }
}

struct TerminalService: View {
    let service: ServiceStatus
    let cached: CachedStatus
    let statistics: DailyStatistics
    let stateStartedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("→")
                    .font(TerminalPalette.body)
                    .foregroundColor(TerminalPalette.dim)
                Text(service.model)
                    .font(TerminalPalette.model)
                    .foregroundColor(TerminalPalette.primary)
                    .lineLimit(1)
                Text("·")
                    .font(TerminalPalette.body)
                    .foregroundColor(TerminalPalette.dim)
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                Text(stateLabel)
                    .font(TerminalPalette.body)
                    .foregroundColor(stateColor)
                Spacer(minLength: 4)
                Text(latency)
                    .font(TerminalPalette.meta)
                    .foregroundColor(TerminalPalette.dim)
            }
            HStack {
                Text("uptime \(uptime) · 60m \(successRate) · \(coverage)")
                Spacer()
            }
            .padding(.leading, 22)
            .font(TerminalPalette.meta)
            .foregroundColor(TerminalPalette.dim)
            TerminalHistory(probes: service.history)
                .padding(.top, 4)
            HStack {
                Text("-60m")
                Spacer()
                Text("-1m")
            }
            .font(TerminalPalette.axis)
            .foregroundColor(TerminalPalette.dim)
            statusReport
        }
    }

    private var statusReport: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(stateIcon) 模型状态变更：\(stateDescription)")
            Text("\(stateDescription)时间：\(formatDuration(Date().timeIntervalSince(stateStartedAt ?? service.last?.timestamp ?? Date())))")
            Text("监控模型：\(service.model)")
            Text("确认时间：\(confirmationTime)")
            Text("今日统计（\(today), 北京时间）")
                .padding(.top, 5)
                .foregroundColor(TerminalPalette.primary)
            Text("今日运行时间：\(formatDuration(statistics.normal))")
            Text("今日异常时间：\(formatDuration(statistics.abnormal))")
            Text("今日异常次数：\(statistics.incidents) 次")
            Text("今日可用率：\(availabilityText)")
        }
        .padding(.top, 8)
        .padding(.leading, 22)
        .font(TerminalPalette.report)
        .foregroundColor(TerminalPalette.dim)
    }

    private var availabilityText: String {
        String(format: "%.2f%%", statistics.availability)
    }

    private var stateIcon: String { stateLabel == "online" ? "✓" : "✕" }

    private var stateDescription: String {
        switch stateLabel {
        case "online": return "正常运行"
        case "offline": return "发生异常"
        case "stale": return "数据已过期"
        default: return "尚未确认"
        }
    }
    private var confirmationTime: String { (service.last?.timestamp ?? cached.snapshot.generatedAt).formatted(date: .numeric, time: .standard) }
    private var today: String { Date().formatted(.iso8601.year().month().day()) }
    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        return minutes < 60 ? String(format: "%.1f 分钟", interval / 60) : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    private var isStale: Bool {
        cached.isStale || service.last.map { Date().timeIntervalSince($0.timestamp) > 600 } == true
    }

    private var stateLabel: String {
        if isStale { return "stale" }
        guard let last = service.last else { return "unknown" }
        return last.ok ? "online" : "offline"
    }

    private var stateColor: Color {
        if isStale { return TerminalPalette.amber }
        guard let last = service.last else { return TerminalPalette.dim }
        return last.ok ? TerminalPalette.green : TerminalPalette.red
    }

    private var latency: String {
        guard let value = service.last?.latencyMS, !isStale else { return "--" }
        return "\(value) ms"
    }

    private var uptime: String {
        guard let value = service.uptimePercent else { return "--" }
        return String(format: "%.2f%%", value)
    }

    private var successRate: String {
        let values = service.history
        guard !values.isEmpty else { return "--" }
        let succeeded = values.filter(\.ok).count
        return String(format: "%.1f%%", Double(succeeded) / Double(values.count) * 100)
    }

    private var coverage: String {
        let count = service.history.count
        return count >= 60 ? "60/60" : "\(count)/60 · miss \(60 - count)m"
    }
}

struct TerminalHistory: View {
    let probes: [Probe]

    var body: some View {
        GeometryReader { geometry in
            let count = 60
            let spacing: CGFloat = 2
            let width = max(2, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(0..<count), id: \.self) { index in
                    let probe = probeForSlot(index)
                    Capsule()
                        .fill(color(for: probe))
                        .frame(width: width, height: probe == nil ? 6 : 15)
                }
            }
        }
        .frame(height: 15)
    }

    private func probeForSlot(_ index: Int) -> Probe? {
        guard !probes.isEmpty else { return nil }
        let sorted = probes.sorted { $0.timestamp < $1.timestamp }
        let start = Date().addingTimeInterval(-3600)
        let end = Date()
        let bucket = start.addingTimeInterval(Double(index) * 60)
        let next = index == 59 ? end : bucket.addingTimeInterval(60)
        return sorted.last(where: { $0.timestamp >= bucket && $0.timestamp < next })
    }

    private func color(for probe: Probe?) -> Color {
        guard let probe else { return TerminalPalette.missing }
        return probe.ok ? TerminalPalette.green : TerminalPalette.red
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: StatusStore

    var body: some View {
        NavigationView {
            Form {
                Section("刷新") {
                    LabeledContent("前台刷新周期", value: "30 秒")
                    LabeledContent("后台主链路", value: "SpringBoard → DEB")
                    LabeledContent("本次启动刷新", value: "\(store.refreshCount) 次")
                }
                Section("后台插件") {
                    LabeledContent("插件状态", value: store.pluginStatus == nil ? "未连接" : "运行中")
                    if let plugin = store.pluginStatus {
                        LabeledContent("插件请求次数", value: "\(plugin.attempts) 次")
                        LabeledContent("插件成功 / 失败", value: "\(plugin.successes) / \(plugin.failures)")
                        LabeledContent("插件最近请求", value: pluginDate(plugin.lastAttempt))
                        LabeledContent("插件最近间隔", value: pluginInterval(plugin.lastInterval))
                        if let error = plugin.lastError { Text(error).font(.footnote).foregroundColor(.orange) }
                    } else {
                        Text("未检测到 RootHide 后台插件，请先安装 DEB 并重启插件服务。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                Section("后台实际记录") {
                    LabeledContent("系统 fetch 调用", value: "\(store.diagnostics.backgroundFetches) 次")
                    LabeledContent("后台成功 / 失败", value: "\(store.diagnostics.backgroundSuccesses) / \(store.diagnostics.backgroundFailures)")
                    Text("后台由 SpringBoard Darwin 通知唤醒 DEB；iOS 系统 fetch 仅作为兼容回退。这里记录 IPA 实际回调与请求结果。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("实际请求记录") {
                    LabeledContent("最后一次尝试", value: diagnosticDate(store.diagnostics.lastAttemptAt))
                    LabeledContent("最后一次成功", value: diagnosticDate(store.diagnostics.lastSuccessAt))
                    LabeledContent("最后一次失败", value: diagnosticDate(store.diagnostics.lastFailureAt))
                    LabeledContent("最近请求间隔", value: intervalText(store.diagnostics.lastInterval))
                    LabeledContent("最长请求间隔", value: intervalText(store.diagnostics.maxInterval))
                    LabeledContent("最近执行来源", value: store.diagnostics.lastExecutionSource)
                    LabeledContent("累计成功 / 失败", value: "\(store.diagnostics.successfulAttempts) / \(store.diagnostics.failedAttempts)")
                    if let error = store.diagnostics.lastError {
                        Text(error).font(.footnote).foregroundColor(.orange)
                    }
                }
                Section("关于") {
                    Link("打开官方状态页", destination: URL(string: "https://status.input.im/")!)
                    Text("AI INPUT Status 3.3.0").foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func pluginDate(_ value: TimeInterval) -> String {
        guard value > 0 else { return "--" }
        return Date(timeIntervalSince1970: value).formatted(date: .omitted, time: .standard)
    }

    private func pluginInterval(_ value: TimeInterval) -> String {
        guard value > 0 else { return "--" }
        return String(format: "%.1f 秒", value)
    }

    private func diagnosticDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func intervalText(_ interval: TimeInterval?) -> String {
        guard let interval else { return "--" }
        return String(format: "%.1f 秒", interval)
    }
}

enum TerminalPalette {
    static let background = Color(red: 0.015, green: 0.025, blue: 0.022)
    static let green = Color(red: 0.18, green: 0.92, blue: 0.50)
    static let red = Color(red: 1.00, green: 0.38, blue: 0.46)
    static let amber = Color(red: 1.00, green: 0.73, blue: 0.30)
    static let missing = Color(red: 0.10, green: 0.16, blue: 0.13)
    static let primary = Color(red: 0.92, green: 0.96, blue: 0.93)
    static let dim = Color(red: 0.55, green: 0.63, blue: 0.58)
    static let rule = Color(red: 0.12, green: 0.20, blue: 0.16)
    static let brand = Font.system(size: 17, weight: .bold, design: .monospaced)
    static let model = Font.system(size: 17, weight: .bold, design: .monospaced)
    static let body = Font.system(size: 15, weight: .regular, design: .monospaced)
    static let meta = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let axis = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let footer = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let report = Font.system(size: 11, weight: .regular, design: .monospaced)
}
