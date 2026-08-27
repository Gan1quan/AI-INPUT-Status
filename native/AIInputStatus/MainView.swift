import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: StatusStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var diagnosticsExpanded = false
    @State private var eventsExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HeaderView(showingSettings: $showingSettings)
                    if let snapshot = store.snapshot {
                        StatusOverview(snapshot: snapshot, store: store)
                        DividerLine()
                        SubscriptionPanel(store: store, showSettings: { showingSettings = true })
                        if !StatusEngine.diagnostics(snapshot, settings: store.notificationSettings).isEmpty {
                            DividerLine()
                            DiagnosticsPanel(store: store, expanded: $diagnosticsExpanded)
                        }
                        if !snapshot.customMonitors.isEmpty {
                            DividerLine()
                            CustomResultsPanel(snapshot: snapshot)
                        }
                        if !StatusEngine.loadEvents().isEmpty {
                            DividerLine()
                            EventsPanel(expanded: $eventsExpanded)
                        }
                        FooterView(snapshot: snapshot)
                    } else {
                        LoadingView(error: store.lastError)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await store.refresh(source: "下拉刷新", forceSubscription: true) }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(store: store) }
        .onAppear { store.startForegroundLoop() }
        .onChange(of: scenePhase) { phase in store.sceneChanged(phase) }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var store: StatusStore
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("AI INPUT")
                .font(AppTheme.monoTitle)
                .foregroundColor(AppTheme.green)
            Spacer()
            Text(store.gatewayLabel)
                .font(AppTheme.monoBody)
                .foregroundColor(store.snapshot?.gateway?.classification == .ok ? AppTheme.green : AppTheme.amber)
                .lineLimit(1)
            Link(destination: gatewayEndpoint) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.secondary)
            }
            Button { showingSettings = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(AppTheme.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StatusOverview: View {
    let snapshot: StatusSnapshot
    @ObservedObject var store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(store.historyRange.label) history · \(StatusEngine.dataTrustLabel(snapshot))")
                    .font(AppTheme.monoBody)
                    .foregroundColor(AppTheme.secondary)
                Spacer()
                if store.isRefreshing {
                    ProgressView().scaleEffect(0.65).tint(AppTheme.green)
                }
            }
            .padding(.top, 22)
            .padding(.bottom, 13)
            ForEach(snapshot.services) { service in
                ServicePanel(service: service, range: store.historyRange)
            }
            HStack {
                Text("历史窗口")
                Spacer()
                ForEach(HistoryRange.allCases, id: \.self) { range in
                    Button(range.label) { store.historyRange = range }
                        .font(AppTheme.monoSmall)
                        .foregroundColor(store.historyRange == range ? AppTheme.green : AppTheme.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(store.historyRange == range ? AppTheme.green.opacity(0.12) : Color.clear)
                        .cornerRadius(4)
                }
            }
            .font(AppTheme.monoSmall)
            .foregroundColor(AppTheme.secondary)
            .padding(.top, 10)
        }
    }
}

private struct ServicePanel: View {
    let service: ServiceStatus
    let range: HistoryRange

    var body: some View {
        let state = StatusEngine.serviceState(service)
        let summary = StatusEngine.historySummary(service, range: range)
        let stats = StatusEngine.latencyStats(service, range: range)
        let failureMinutes = StatusEngine.consecutiveFailureMinutes(service)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("→").font(AppTheme.monoBody).foregroundColor(AppTheme.secondary)
                Text(service.model).font(AppTheme.monoModel).foregroundColor(AppTheme.primary).lineLimit(1)
                Text("·").font(AppTheme.monoBody).foregroundColor(AppTheme.secondary)
                Circle().fill(stateColor(state)).frame(width: 8, height: 8)
                Text(stateText(state)).font(AppTheme.monoBody).foregroundColor(stateColor(state))
                Spacer(minLength: 5)
                Text(latency(service.last?.latencyMS)).font(AppTheme.monoMeta).foregroundColor(AppTheme.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("uptime \(uptime(service.uptimePercent)) · \(range.label) \(successRate(summary.successRate)) · \(summary.observed)/\(range.rawValue)")
                if summary.missing > 0 { Text("· miss \(summary.missing)m") }
                if failureMinutes >= 2 { Text("· fail \(failureMinutes)m") }
                Spacer(minLength: 4)
                if let median = stats.median { Text("p50 \(median) ms") }
            }
            .font(AppTheme.monoMeta)
            .foregroundColor(AppTheme.secondary)
            .padding(.leading, 28)
            .padding(.top, 3)
            HistoryBar(summary: summary)
                .padding(.top, 9)
            HStack {
                Text("-\(range.rawValue)m")
                Spacer()
                Text("-1m")
            }
            .font(AppTheme.monoSmall)
            .foregroundColor(AppTheme.secondary)
            .padding(.top, 3)
        }
        .padding(.vertical, 7)
    }

    private func uptime(_ value: Double?) -> String { value.map { String(format: "%.2f%%", $0) } ?? "--" }
    private func successRate(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "--" }
    private func latency(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "--" }
}

private struct HistoryBar: View {
    let summary: HistorySummary

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, summary.slots.count)
            let spacing: CGFloat = summary.slots.count > 120 ? 0.45 : 1.2
            let width = max(1.2, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(spacing: spacing) {
                ForEach(Array(summary.slots.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(value == true ? AppTheme.green : value == false ? AppTheme.red : AppTheme.missing)
                        .frame(width: width, height: value == nil ? 8 : 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 16)
    }
}

private struct SubscriptionPanel: View {
    @ObservedObject var store: StatusStore
    let showSettings: () -> Void

    var body: some View {
        let snapshot = store.subscription
        let plans = SubscriptionEngine.sortedPlans(snapshot?.plans ?? []).filter { $0.isActive() }
        let summary = SubscriptionEngine.summary(plans)
        let health = SubscriptionEngine.health(snapshot, tokenConfigured: store.tokenConfigured, error: store.subscriptionError)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("订阅额度").font(.system(size: 21, weight: .bold)).foregroundColor(AppTheme.primary)
                Spacer()
                Text(SubscriptionEngine.healthLabel(health)).font(AppTheme.monoMeta).foregroundColor(subscriptionColor(health))
            }
            .padding(.top, 22)
            .padding(.bottom, 9)
            if plans.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.tokenConfigured ? "正在读取订阅额度" : "未配置订阅 Token")
                        .font(AppTheme.monoBody).foregroundColor(AppTheme.secondary)
                    Spacer()
                    Button(store.tokenConfigured ? "刷新" : "配置") { showSettings() }
                        .font(AppTheme.monoMeta).foregroundColor(AppTheme.green)
                }
                if let error = store.subscriptionError {
                    Text(error).font(AppTheme.monoSmall).foregroundColor(AppTheme.amber).padding(.top, 5)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("今日总剩余").font(AppTheme.monoBody).foregroundColor(AppTheme.secondary)
                    Spacer()
                    Text("\(money(summary.totalRemainingUSD)) / \(money(summary.totalLimitUSD))")
                        .font(.system(size: 21, weight: .bold, design: .monospaced)).foregroundColor(AppTheme.green)
                }
                .padding(.bottom, 3)
                HStack {
                    Text("\(summary.activePlans) 个有效套餐")
                    Spacer()
                    Text("\(SubscriptionEngine.resetLabel()) · \(SubscriptionEngine.freshnessLabel(snapshot))")
                }
                .font(AppTheme.monoMeta).foregroundColor(AppTheme.secondary).padding(.bottom, 8)
                ForEach(plans) { plan in PlanRow(plan: plan) }
                let trend = SubscriptionEngine.trend(plans)
                HStack {
                    Text(trend.label)
                    if let estimate = trend.estimate { Text("· \(estimate)") }
                    Spacer()
                }
                .font(AppTheme.monoSmall).foregroundColor(AppTheme.secondary).padding(.top, 3)
            }
        }
    }

    private func subscriptionColor(_ health: SubscriptionHealth) -> Color {
        switch health {
        case .ready: return AppTheme.green
        case .cached, .stale: return AppTheme.amber
        case .unconfigured, .unknown: return AppTheme.secondary
        default: return AppTheme.red
        }
    }
}

private struct PlanRow: View {
    let plan: SubscriptionPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "creditcard.fill").foregroundColor(AppTheme.green)
                Text(plan.name).font(.system(size: 19, weight: .bold)).foregroundColor(AppTheme.primary).lineLimit(1)
                Spacer()
                Text("有效").font(AppTheme.monoBody).foregroundColor(AppTheme.green)
            }
            .padding(.top, 8)
            HStack(alignment: .firstTextBaseline) {
                Text("每日 \(money(plan.dailyUsageUSD)) / \(money(plan.dailyLimitUSD))")
                    .font(AppTheme.monoBody).foregroundColor(AppTheme.secondary)
                Spacer()
                Text("剩余 \(money(plan.remainingUSD))")
                    .font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundColor(AppTheme.green)
            }
            .padding(.top, 6)
            ProgressBar(value: plan.usagePercent)
                .padding(.top, 8)
            HStack(alignment: .firstTextBaseline) {
                Text("已用 \(String(format: "%.1f", plan.usagePercent))%")
                Spacer()
                Text("本周 \(money(plan.weeklyUsageUSD)) · 本月 \(money(plan.monthlyUsageUSD)) · \(SubscriptionEngine.expiryLabel(plan.expiresAt))")
            }
            .font(AppTheme.monoMeta).foregroundColor(AppTheme.secondary).padding(.top, 5)
            DividerLine().padding(.top, 8)
        }
    }
}

private struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.missing.opacity(0.55))
                Capsule().fill(value >= 90 ? AppTheme.red : value >= 70 ? AppTheme.amber : AppTheme.green)
                    .frame(width: max(value > 0 ? 2 : 0, geometry.size.width * min(100, max(0, value)) / 100))
            }
        }
        .frame(height: 6)
    }
}

private struct DiagnosticsPanel: View {
    @ObservedObject var store: StatusStore
    @Binding var expanded: Bool

    var body: some View {
        let items = store.snapshot.map { StatusEngine.diagnostics($0, settings: store.notificationSettings) } ?? []
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.severity == .failure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(item.severity == .failure ? AppTheme.red : AppTheme.amber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(AppTheme.monoBody).foregroundColor(AppTheme.primary)
                            Text(item.detail).font(AppTheme.monoSmall).foregroundColor(AppTheme.secondary)
                        }
                    }
                }
            }
            .padding(.top, 9)
        } label: {
            HStack {
                Text("诊断 · \(items.count) 项").font(.system(size: 18, weight: .bold)).foregroundColor(AppTheme.primary)
                Spacer()
                if items.isEmpty { Image(systemName: "checkmark.circle.fill").foregroundColor(AppTheme.green) }
            }
        }
        .tint(AppTheme.secondary)
        .padding(.top, 18)
    }
}

private struct CustomResultsPanel: View {
    let snapshot: StatusSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自定义监测").font(.system(size: 18, weight: .bold)).foregroundColor(AppTheme.primary)
            ForEach(snapshot.customMonitors) { result in
                HStack {
                    Circle().fill(result.classification == "ok" ? AppTheme.green : AppTheme.red).frame(width: 7, height: 7)
                    Text(result.label).font(AppTheme.monoBody).foregroundColor(AppTheme.primary)
                    Spacer()
                    Text(result.detail).font(AppTheme.monoSmall).foregroundColor(result.classification == "ok" ? AppTheme.secondary : AppTheme.red)
                }
            }
        }
        .padding(.top, 18)
    }
}

private struct EventsPanel: View {
    @Binding var expanded: Bool
    var body: some View {
        let events = Array(StatusEngine.loadEvents().prefix(8))
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: event.phase == .opened ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(event.phase == .opened ? AppTheme.red : AppTheme.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.target) · \(event.phase == .opened ? "异常" : "恢复")").font(AppTheme.monoBody).foregroundColor(AppTheme.primary)
                            Text("\(event.detail) · \(clock(event.date))").font(AppTheme.monoSmall).foregroundColor(AppTheme.secondary)
                        }
                    }
                }
            }
            .padding(.top, 9)
        } label: {
            Text("最近异常事件").font(.system(size: 18, weight: .bold)).foregroundColor(AppTheme.primary)
        }
        .tint(AppTheme.secondary)
        .padding(.top, 18)
    }
}

private struct FooterView: View {
    let snapshot: StatusSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DividerLine().padding(.top, 18)
            Text("data \(clock(snapshot.generatedAt)) · \(StatusEngine.dataTrustLabel(snapshot)) · 更新 \(clock(snapshot.fetchedAt))")
                .font(AppTheme.monoSmall).foregroundColor(AppTheme.secondary)
            if let error = snapshot.lastError {
                Text(error).font(AppTheme.monoSmall).foregroundColor(AppTheme.amber)
            }
        }
    }
}

private struct LoadingView: View {
    let error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().tint(AppTheme.green)
            Text(error ?? "正在读取状态...").font(AppTheme.monoBody).foregroundColor(AppTheme.secondary)
        }
        .padding(.top, 80)
    }
}

private struct DividerLine: View {
    var body: some View { Rectangle().fill(AppTheme.divider).frame(height: 1) }
}
