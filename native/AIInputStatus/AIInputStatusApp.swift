import SwiftUI

@main
struct AIInputStatusApp: App {
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

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts", ok, latencyMS = "latency_ms", error
    }
}

struct ServiceStatus: Codable, Identifiable, Hashable {
    var id: String { model }
    let model: String
    let uptimePercent: Double?
    let last: Probe?
    let history: [Probe]

    enum CodingKeys: String, CodingKey {
        case model, uptimePercent = "uptime_pct", last, history
    }
}

struct Snapshot: Codable, Hashable {
    let generatedAt: Date
    let services: [ServiceStatus]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at", services
    }
}

struct CachedStatus: Codable {
    let snapshot: Snapshot
    let fetchedAt: Date
    let lastError: String?

    var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }
    var isStale: Bool { age > 240 }
}

enum ServiceHealth {
    case operational
    case issue
    case stale
    case unknown

    var color: Color {
        switch self {
        case .operational: return Palette.mint
        case .issue: return Palette.coral
        case .stale: return Palette.amber
        case .unknown: return Palette.muted
        }
    }

    var label: String {
        switch self {
        case .operational: return "运行正常"
        case .issue: return "需要关注"
        case .stale: return "数据过期"
        case .unknown: return "等待数据"
        }
    }
}

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var cached: CachedStatus?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshCount = 0

    private let endpoint = URL(string: "https://status.input.im/api/status")!
    private let cacheKey = "ai-input-status-cache.v2"
    private var refreshTask: Task<Void, Never>?

    init() {
        loadCache()
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

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 12
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let value = CachedStatus(snapshot: try decodeSnapshot(data), fetchedAt: Date(), lastError: nil)
            cached = value
            refreshCount += 1
            saveCache(value)
        } catch {
            guard let old = cached else { return }
            cached = CachedStatus(snapshot: old.snapshot, fetchedAt: old.fetchedAt, lastError: error.localizedDescription)
        }
    }

    func handleScene(_ phase: ScenePhase) {
        if phase == .active { Task { await refresh() } }
    }

    private func decodeSnapshot(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let raw = try decoder.decode(Snapshot.self, from: data)
        let requested = ["gpt-5.6-sol", "gpt-5.6-terra"]
        let services = requested.map { model in
            raw.services.first(where: { $0.model == model }) ?? ServiceStatus(model: model, uptimePercent: nil, last: nil, history: [])
        }
        return Snapshot(generatedAt: raw.generatedAt, services: services)
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let value = try? JSONDecoder().decode(CachedStatus.self, from: data) else { return }
        cached = value
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
                VStack(spacing: 24) {
                    topBar
                    if let cached = store.cached {
                        StatusHero(status: overallHealth(cached), cached: cached)
                        serviceSection(cached)
                        historySection(cached)
                        footer(cached)
                    } else {
                        loading
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 34)
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(store) }
        }
        .navigationViewStyle(.stack)
        .onChange(of: scenePhase) { store.handleScene($0) }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("AI INPUT")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .tracking(1.1)
                Text("服务可用性监测")
                    .font(.subheadline)
                    .foregroundColor(Palette.secondaryText)
            }
            Spacer()
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 0.85).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
            }
            .buttonStyle(CircleActionStyle())
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(CircleActionStyle())
        }
    }

    private func serviceSection(_ cached: CachedStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "服务状态", detail: "自动刷新 · 30 秒")
            ForEach(cached.snapshot.services) { service in
                ServiceCard(service: service, health: health(for: service, cached: cached))
            }
        }
    }

    private func historySection(_ cached: CachedStatus) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeader(title: "最近探测", detail: "每格代表一次记录")
            VStack(spacing: 17) {
                ForEach(cached.snapshot.services) { service in
                    HistoryRow(service: service)
                }
            }
            .padding(18)
            .background(Panel(cornerRadius: 22))
        }
    }

    private func footer(_ cached: CachedStatus) -> some View {
        VStack(spacing: 7) {
            Text("状态源：status.input.im · 更新于 \(relativeTime(cached.fetchedAt))")
            if let error = cached.lastError {
                Text("本机刷新未成功，正在展示上次有效数据：\(friendlyError(error))")
                    .foregroundColor(Palette.amber)
            }
        }
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundColor(Palette.secondaryText)
        .frame(maxWidth: .infinity)
    }

    private var loading: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white)
            Text("正在获取状态数据")
                .foregroundColor(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 150)
    }

    private func overallHealth(_ cached: CachedStatus) -> ServiceHealth {
        if cached.isStale { return .stale }
        let states = cached.snapshot.services.map { health(for: $0, cached: cached) }
        if states.allSatisfy({ $0 == .operational }) { return .operational }
        if states.contains(where: { health in
            if case .issue = health { return true }
            return false
        }) { return .issue }
        return .unknown
    }

    private func health(for service: ServiceStatus, cached: CachedStatus) -> ServiceHealth {
        if cached.isStale { return .stale }
        guard let probe = service.last else { return .unknown }
        if Date().timeIntervalSince(probe.timestamp) > 600 { return .stale }
        return probe.ok ? .operational : .issue
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 10 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        return "\(seconds / 60) 分钟前"
    }

    private func friendlyError(_ error: String) -> String {
        error.contains("timed out") ? "请求超时" : "网络暂不可用"
    }
}

struct StatusHero: View {
    let status: ServiceHealth
    let cached: CachedStatus

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(status.color.opacity(0.15)).frame(width: 54, height: 54)
                Circle().stroke(status.color.opacity(0.42), lineWidth: 1).frame(width: 54, height: 54)
                Image(systemName: status == .operational ? "checkmark" : "exclamationmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(status.color)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(status.label).font(.system(size: 23, weight: .bold, design: .rounded))
                Text(detail).font(.subheadline).foregroundColor(Palette.secondaryText)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text("数据生成于 \(cached.snapshot.generatedAt.formatted(date: .omitted, time: .shortened))")
                }
                .font(.caption)
                .foregroundColor(Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(HeroPanel(color: status.color))
    }

    private var detail: String {
        switch status {
        case .operational: return "当前两个模型均通过最近一次探测"
        case .issue: return "至少一个模型最近一次探测未通过"
        case .stale: return "展示的是超过 4 分钟的缓存数据"
        case .unknown: return "状态源尚未提供可判断的结果"
        }
    }
}

struct ServiceCard: View {
    let service: ServiceStatus
    let health: ServiceHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(service.model)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    HStack(spacing: 7) {
                        Circle().fill(health.color).frame(width: 7, height: 7)
                        Text(health.label)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundColor(health.color)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(uptime)
                        .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    Text("统计可用率")
                        .font(.caption2)
                        .foregroundColor(Palette.secondaryText)
                }
            }
            Divider().background(Color.white.opacity(0.09))
            HStack {
                Label(probeDetail, systemImage: health == .operational ? "bolt.horizontal.circle" : "waveform.path.ecg")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(Palette.secondaryText)
                Spacer()
                Text(lastTime)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Palette.secondaryText)
            }
        }
        .padding(18)
        .background(Panel(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(health.color.opacity(0.15), lineWidth: 1))
    }

    private var uptime: String {
        guard let value = service.uptimePercent else { return "--" }
        return String(format: "%.1f%%", value)
    }

    private var probeDetail: String {
        guard let probe = service.last else { return "状态源未返回最近探测" }
        if probe.ok { return probe.latencyMS.map { "最近响应 \($0) ms" } ?? "最近探测通过" }
        if let error = probe.error, !error.isEmpty { return "探测返回：\(error)" }
        return "最近探测未通过"
    }

    private var lastTime: String {
        guard let date = service.last?.timestamp else { return "--" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct HistoryRow: View {
    let service: ServiceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(service.model).font(.subheadline.weight(.semibold))
                Spacer()
                Text(summary).font(.caption).foregroundColor(Palette.secondaryText)
            }
            HistoryStrip(probes: Array(service.history.suffix(36)))
        }
    }

    private var summary: String {
        guard !service.history.isEmpty else { return "暂无历史记录" }
        let success = service.history.filter(\.ok).count
        return "\(success) / \(service.history.count) 次通过"
    }
}

struct HistoryStrip: View {
    let probes: [Probe]

    var body: some View {
        GeometryReader { geometry in
            let count = max(probes.count, 36)
            let width = max(3, (geometry.size.width - CGFloat(count - 1) * 3) / CGFloat(count))
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    let probe = index < count - probes.count ? nil : probes[index - (count - probes.count)]
                    Capsule()
                        .fill(probe.map { $0.ok ? Palette.mint : Palette.coral } ?? Color.white.opacity(0.09))
                        .frame(width: width, height: probe == nil ? 8 : 18)
                }
            }
        }
        .frame(height: 18)
        .accessibilityLabel("最近探测记录")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: StatusStore

    var body: some View {
        NavigationView {
            Form {
                Section("刷新") {
                    LabeledContent("前台刷新周期", value: "30 秒")
                    LabeledContent("本次启动刷新", value: "\(store.refreshCount) 次")
                }
                Section("关于") {
                    Link("打开官方状态页", destination: URL(string: "https://status.input.im/")!)
                    Text("AI INPUT Status 2.0.0")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            Text(detail).font(.caption).foregroundColor(Palette.secondaryText)
        }
    }
}

struct Palette {
    static let mint = Color(red: 0.30, green: 0.90, blue: 0.70)
    static let coral = Color(red: 1.00, green: 0.43, blue: 0.46)
    static let amber = Color(red: 0.98, green: 0.72, blue: 0.30)
    static let muted = Color(red: 0.56, green: 0.61, blue: 0.72)
    static let secondaryText = Color.white.opacity(0.57)
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.075)
            Circle().fill(Color(red: 0.14, green: 0.32, blue: 0.53).opacity(0.24)).blur(radius: 75).offset(x: 155, y: -290)
            Circle().fill(Palette.mint.opacity(0.10)).blur(radius: 90).offset(x: -175, y: 340)
        }
    }
}

struct Panel: View {
    let cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct HeroPanel: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.24), Color.white.opacity(0.075)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.13), lineWidth: 1))
    }
}

struct CircleActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 40, height: 40)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            .clipShape(Circle())
    }
}
