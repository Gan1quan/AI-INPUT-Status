import Foundation
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
        let models = ["gpt-5.6-sol", "gpt-5.6-terra"]
        let services = models.map { model in
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
                VStack(alignment: .leading, spacing: 0) {
                    terminalHeader
                    Rectangle().fill(TerminalPalette.rule).frame(height: 1).padding(.vertical, 16)
                    if let cached = store.cached {
                        terminalBody(cached)
                    } else {
                        Text("connecting to status.input.im ...")
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
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(store) }
        }
        .navigationViewStyle(.stack)
        .onChange(of: scenePhase) { store.handleScene($0) }
    }

    private var terminalHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("AI INPUT")
                .font(TerminalPalette.brand)
                .foregroundColor(TerminalPalette.green)
            Spacer()
            Text("api \(apiLabel)")
                .font(TerminalPalette.meta)
                .foregroundColor(apiColor)
            Button { Task { await store.refresh() } } label: {
                Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(TerminalPalette.dim)
            }
            .buttonStyle(.plain)
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
                TerminalService(service: service, cached: cached)
            }
            Rectangle().fill(TerminalPalette.rule).frame(height: 1).padding(.top, 2)
            HStack(alignment: .firstTextBaseline) {
                Text("data \(clock(cached.snapshot.generatedAt))")
                Spacer()
                Text("run \(clock(cached.fetchedAt)) · Δ30s")
            }
            .font(TerminalPalette.footer)
            .foregroundColor(cached.lastError == nil ? TerminalPalette.dim : TerminalPalette.amber)
            if cached.lastError != nil {
                Text("last fetch failed · showing cached status")
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

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

struct TerminalService: View {
    let service: ServiceStatus
    let cached: CachedStatus

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
        }
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
                    LabeledContent("本次启动刷新", value: "\(store.refreshCount) 次")
                }
                Section("关于") {
                    Link("打开官方状态页", destination: URL(string: "https://status.input.im/")!)
                    Text("AI INPUT Status 3.0.0").foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
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
}
