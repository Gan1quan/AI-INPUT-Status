import SwiftUI

@main
struct AIInputStatusApp: App {
    @StateObject private var model = StatusStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct Probe: Codable, Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let ok: Bool
    let latencyMS: Int?
    let error: String?

    enum CodingKeys: String, CodingKey { case timestamp = "ts", ok, latencyMS = "latency_ms", error }
}

struct ServiceStatus: Codable, Identifiable, Hashable {
    var id: String { model }
    let model: String
    let uptimePercent: Double
    let last: Probe?
    let history: [Probe]

    enum CodingKeys: String, CodingKey { case model, uptimePercent = "uptime_pct", last, history }
}

struct Snapshot: Codable, Hashable {
    let allOK: Bool
    let generatedAt: Date
    let services: [ServiceStatus]

    enum CodingKeys: String, CodingKey { case allOK = "all_ok", generatedAt = "generated_at", services }
}

struct CachedStatus: Codable {
    let snapshot: Snapshot
    let fetchedAt: Date
    let lastError: String?

    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 240 }
}

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var cached: CachedStatus?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var refreshCount = 0
    @Published var notificationsEnabled = false

    private let endpoint = URL(string: "https://status.input.im/api/status")!
    private var refreshTask: Task<Void, Never>?
    private let cacheKey = "ai-input-status-cache.v1"

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
        lastAttempt = Date()
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
            let snapshot = try decodeSnapshot(data)
            let value = CachedStatus(snapshot: snapshot, fetchedAt: Date(), lastError: nil)
            cached = value
            refreshCount += 1
            saveCache(value)
        } catch {
            if let old = cached {
                cached = CachedStatus(snapshot: old.snapshot, fetchedAt: old.fetchedAt, lastError: error.localizedDescription)
            }
        }
    }

    func handleScene(_ phase: ScenePhase) {
        if phase == .active { Task { await refresh() } }
    }

    private func decodeSnapshot(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let value = try decoder.decode(Snapshot.self, from: data)
        let selected = value.services.filter { ["gpt-5.6-sol", "gpt-5.6-terra"].contains($0.model) }
        guard !selected.isEmpty else { throw URLError(.cannotParseResponse) }
        return Snapshot(allOK: selected.allSatisfy { $0.last?.ok == true }, generatedAt: value.generatedAt, services: selected)
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey), let value = try? JSONDecoder().decode(CachedStatus.self, from: data) else { return }
        cached = value
    }

    private func saveCache(_ value: CachedStatus) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: StatusStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let cached = store.cached {
                        overview(cached)
                        serviceCards(cached.snapshot.services)
                        history(cached.snapshot.services)
                        footer(cached)
                    } else {
                        loading
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(Background().ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(store) }
        }
        .navigationViewStyle(.stack)
        .onChange(of: scenePhase) { store.handleScene($0) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("AI.INPUT.IM").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(.white)
                Text("模型服务状态").font(.subheadline).foregroundColor(.white.opacity(0.55))
            }
            Spacer()
            HStack(spacing: 10) {
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                }
                .buttonStyle(IconButtonStyle())
                Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(IconButtonStyle())
            }
        }
    }

    private func overview(_ value: CachedStatus) -> some View {
        let ok = value.snapshot.allOK && !value.isStale
        return HStack(spacing: 15) {
            ZStack {
                Circle().stroke((ok ? Color.green : Color.red).opacity(0.22), lineWidth: 8)
                Circle().trim(from: 0, to: 0.76).stroke(ok ? Color.green : Color.red, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: ok ? "checkmark" : "exclamationmark").font(.title2.bold()).foregroundColor(ok ? .green : .red)
            }.frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 6) {
                Text(value.isStale ? "数据已过期" : (ok ? "全部正常" : "服务异常")).font(.title2.bold()).foregroundColor(.white)
                Text(ok ? "两个模型均可用" : "请查看下方服务详情").font(.subheadline).foregroundColor(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(18).background(Glass()).overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08)))
    }

    private func serviceCards(_ services: [ServiceStatus]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("服务概览", trailing: "前台每 30 秒更新")
            ForEach(services) { service in ServiceCard(service: service) }
        }
    }

    private func history(_ services: [ServiceStatus]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("最近探测", trailing: "60 次窗口")
            ForEach(services) { service in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(service.model).font(.subheadline.weight(.semibold)).foregroundColor(.white); Spacer(); Text("成功率 \(observedRate(service), specifier: "%.1f")%").font(.caption).foregroundColor(.white.opacity(0.5)) }
                    HistoryBars(probes: Array(service.history.suffix(60)))
                }.padding(16).background(Glass())
            }
        }
    }

    private func footer(_ value: CachedStatus) -> some View {
        VStack(spacing: 6) {
            Text("数据时间  \(value.snapshot.generatedAt.formatted(date: .omitted, time: .shortened))  ·  更新于 \(value.fetchedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundColor(.white.opacity(0.45))
            if let error = value.lastError { Text("上次请求失败：\(error)").font(.caption2).foregroundColor(.orange).lineLimit(2) }
        }.frame(maxWidth: .infinity)
    }

    private var loading: some View { VStack(spacing: 12) { ProgressView().tint(.white); Text("正在连接状态服务器").foregroundColor(.white.opacity(0.55)) }.frame(maxWidth: .infinity).padding(.top, 120) }
    private func sectionTitle(_ title: String, trailing: String) -> some View { HStack { Text(title).font(.headline).foregroundColor(.white); Spacer(); Text(trailing).font(.caption).foregroundColor(.white.opacity(0.42)) } }
    private func observedRate(_ service: ServiceStatus) -> Double { let probes = service.history.filter { $0.ok }; return service.history.isEmpty ? 0 : Double(probes.count) / Double(service.history.count) * 100 }
}

struct ServiceCard: View {
    let service: ServiceStatus
    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(service.last?.ok == true ? Color.green : Color.red).frame(width: 12, height: 12).shadow(color: (service.last?.ok == true ? Color.green : Color.red).opacity(0.65), radius: 7)
            VStack(alignment: .leading, spacing: 5) { Text(service.model).font(.headline).foregroundColor(.white); Text(service.last?.ok == true ? "在线 · 最近响应正常" : (service.last?.error ?? "最近探测失败")).font(.caption).foregroundColor(.white.opacity(0.5)).lineLimit(1) }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) { Text("\(service.uptimePercent, specifier: "%.1f")%").font(.headline.monospacedDigit()).foregroundColor(.white); Text(service.last?.latencyMS.map { "\($0) ms" } ?? "--").font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.48)) }
        }.padding(16).background(Glass()).overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.07)))
    }
}

struct HistoryBars: View {
    let probes: [Probe]
    var body: some View { HStack(alignment: .bottom, spacing: 2) { ForEach(probes) { probe in RoundedRectangle(cornerRadius: 2).fill(probe.ok ? Color.green.opacity(0.9) : Color.red.opacity(0.9)).frame(maxWidth: .infinity, minHeight: probe.ok ? 18 : 7, maxHeight: probe.ok ? 18 : 7) } }.frame(height: 18) }
}

struct SettingsView: View {
    @EnvironmentObject private var store: StatusStore
    var body: some View {
        NavigationView { Form { Section("刷新") { LabeledContent("前台刷新周期", value: "30 秒"); LabeledContent("刷新次数", value: "\(store.refreshCount)") }; Section("信息") { Link("打开官方状态页", destination: URL(string: "https://status.input.im/")!); Text("AI INPUT Status 1.0.0").foregroundColor(.secondary) } }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline) }
    }
}

struct Background: View { var body: some View { LinearGradient(colors: [Color(red: 0.035, green: 0.045, blue: 0.085), Color(red: 0.075, green: 0.09, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing) } }
struct Glass: View { var body: some View { RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.075)).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 20)) } }
struct IconButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.system(size: 16, weight: .semibold)).foregroundColor(.white).frame(width: 40, height: 40).background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.1)).clipShape(Circle()) } }
