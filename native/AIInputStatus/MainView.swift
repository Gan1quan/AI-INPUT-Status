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
                        SubscriptionPanel(store: store, openSettings: { showingSettings = true })
                        ExtraPanels(snapshot: snapshot, store: store, diagnosticsExpanded: $diagnosticsExpanded, eventsExpanded: $eventsExpanded)
                        FooterView(snapshot: snapshot)
                    } else {
                        LoadingView(message: store.lastError ?? "正在读取状态...")
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await store.refresh(source: "下拉刷新", forceSubscription: true) }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(store: store) }
        .onAppear { store.startForegroundLoop() }
        .onChange(of: scenePhase) { store.sceneChanged($0) }
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
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(store.gatewayLabel)
                .font(AppTheme.monoBody)
                .foregroundColor(gatewayColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Link(destination: gatewayEndpoint) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.secondary)
            }
            Button { showingSettings = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(AppTheme.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
    }

    private var gatewayColor: Color {
        store.snapshot?.gateway?.classification == .ok ? AppTheme.green : AppTheme.amber
    }
}

private struct StatusOverview: View {
    let snapshot: StatusSnapshot
    @ObservedObject var store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(store.historyRange.label) history · \(StatusEngine.dataTrustLabel(snapshot))")
                    .font(AppTheme.monoBody)
                    .foregroundColor(AppTheme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Spacer(minLength: 4)
                if store.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(AppTheme.green)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            ForEach(Array(snapshot.services.enumerated()), id: \.element.id) { index, service in
                ServicePanel(service: service, range: store.historyRange)
                if index < snapshot.services.count - 1 {
                    DividerLine().padding(.vertical, 7)
                }
            }

            HistoryRangePicker(selection: $store.historyRange)
                .padding(.top, 7)
                .padding(.bottom, 11)
        }
    }
}

private struct HistoryRangePicker: View {
    @Binding var selection: HistoryRange

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("历史窗口")
                .font(AppTheme.monoMeta)
                .foregroundColor(AppTheme.secondary)
            Spacer(minLength: 4)
            ForEach(HistoryRange.allCases, id: \.self) { range in
                Button { selection = range } label: {
                    Text(range.label)
                        .font(AppTheme.monoMeta)
                        .foregroundColor(selection == range ? AppTheme.green : AppTheme.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(selection == range ? AppTheme.green.opacity(0.14) : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ServicePanel: View {
    let service: ServiceStatus
    let range: HistoryRange

    private var state: ServiceState { StatusEngine.serviceState(service) }
    private var summary: HistorySummary { StatusEngine.historySummary(service, range: range) }
    private var latencyStats: LatencyStats { StatusEngine.latencyStats(service, range: range) }
    private var failureMinutes: Int { StatusEngine.consecutiveFailureMinutes(service) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("→")
                    .font(AppTheme.monoBody)
                    .foregroundColor(AppTheme.secondary)
                Text(service.model)
                    .font(AppTheme.monoModel)
                    .foregroundColor(AppTheme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("·")
                    .font(AppTheme.monoBody)
                    .foregroundColor(AppTheme.secondary)
                Circle()
                    .fill(stateColor(state))
                    .frame(width: 8, height: 8)
                Text(stateText(state))
                    .font(AppTheme.monoBody)
                    .foregroundColor(stateColor(state))
                    .lineLimit(1)
                Spacer(minLength: 5)
                Text(latencyLabel)
                    .font(AppTheme.monoMeta)
                    .foregroundColor(AppTheme.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                Text("uptime \(percentLabel(service.uptimePercent, digits: 2))")
                Text(" · \(range.label) \(percentLabel(summary.successRate, digits: 1))")
                Text(" · \(summary.observed)/\(range.rawValue)")
            }
            .font(AppTheme.monoMeta)
            .foregroundColor(AppTheme.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.leading, 29)
            .padding(.top, 4)

            HStack(spacing: 0) {
                if summary.missing > 0 { Text("miss \(summary.missing)m") }
                if failureMinutes >= 2 {
                    if summary.missing > 0 { Text(" · ") }
                    Text("fail \(failureMinutes)m")
                }
                if let median = latencyStats.median {
                    if summary.missing > 0 || failureMinutes >= 2 { Text(" · ") }
                    Text("p50 \(median) ms")
                }
                Spacer(minLength: 4)
            }
            .font(AppTheme.monoSmall)
            .foregroundColor(failureMinutes >= 2 ? AppTheme.red : AppTheme.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.leading, 29)
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
        .padding(.vertical, 3)
    }

    private var latencyLabel: String {
        service.last?.latencyMS.map { "\($0) ms" } ?? "--"
    }

    private func percentLabel(_ value: Double?, digits: Int) -> String {
        guard let value else { return "--" }
        return String(format: "%.*f%%", digits, value)
    }
}

private struct HistoryBar: View {
    let summary: HistorySummary

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, summary.slots.count)
            let gap: CGFloat = summary.slots.count > 120 ? 0.45 : 1.0
            let width = max(1.2, (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(spacing: gap) {
                ForEach(Array(summary.slots.enumerated()), id: \.offset) { item in
                    Capsule()
                        .fill(color(item.element))
                        .frame(width: width, height: item.element == nil ? 7 : 15)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 15)
    }

    private func color(_ value: Bool?) -> Color {
        value == true ? AppTheme.green : value == false ? AppTheme.red : AppTheme.missing
    }
}

private struct SubscriptionPanel: View {
    @ObservedObject var store: StatusStore
    let openSettings: () -> Void

    private var snapshot: SubscriptionSnapshot? { store.subscription }
    private var plans: [SubscriptionPlan] {
        SubscriptionEngine.sortedPlans(snapshot?.plans ?? []).filter { $0.isActive() }
    }
    private var summary: SubscriptionSummary { SubscriptionEngine.summary(plans) }
    private var health: SubscriptionHealth {
        SubscriptionEngine.health(snapshot, tokenConfigured: store.tokenConfigured, error: store.subscriptionError)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("订阅额度")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(AppTheme.primary)
                Spacer(minLength: 5)
                Text(SubscriptionEngine.healthLabel(health))
                    .font(AppTheme.monoMeta)
                    .foregroundColor(healthColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(.top, 19)
            .padding(.bottom, 9)

            if plans.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.tokenConfigured ? "正在读取订阅额度" : "未配置订阅 Token")
                        .font(AppTheme.monoBody)
                        .foregroundColor(AppTheme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 5)
                    Button(store.tokenConfigured ? "刷新" : "配置", action: openSettings)
                        .font(AppTheme.monoMeta)
                        .foregroundColor(AppTheme.green)
                }
                if let error = store.subscriptionError {
                    Text(error)
                        .font(AppTheme.monoSmall)
                        .foregroundColor(AppTheme.amber)
                        .padding(.top, 6)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("今日总剩余")
                        .font(AppTheme.monoBody)
                        .foregroundColor(AppTheme.secondary)
                    Spacer(minLength: 5)
                    Text("\(money(summary.totalRemainingUSD)) / \(money(summary.totalLimitUSD))")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(AppTheme.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(summary.activePlans) 个有效套餐")
                    Spacer(minLength: 5)
                    Text("\(SubscriptionEngine.resetLabel()) · \(SubscriptionEngine.freshnessLabel(snapshot))")
                        .multilineTextAlignment(.trailing)
                }
                .font(AppTheme.monoMeta)
                .foregroundColor(AppTheme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .padding(.top, 4)
                .padding(.bottom, 4)

                ForEach(plans) { plan in
                    PlanRow(plan: plan)
                }

                let trend = SubscriptionEngine.trend(plans)
                HStack(spacing: 4) {
                    Text(trend.label)
                    if let estimate = trend.estimate { Text("· \(estimate)") }
                    Spacer()
                }
                .font(AppTheme.monoSmall)
                .foregroundColor(AppTheme.secondary)
                .padding(.top, 2)
            }
        }
    }

    private var healthColor: Color {
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
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppTheme.green)
                Text(plan.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 5)
                Text("有效")
                    .font(AppTheme.monoBody)
                    .foregroundColor(AppTheme.green)
            }
            .padding(.top, 8)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("每日 \(money(plan.dailyUsageUSD)) / \(money(plan.dailyLimitUSD))")
                    .font(AppTheme.monoBody)
                    .foregroundColor(AppTheme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Spacer(minLength: 5)
                Text("剩余 \(money(plan.remainingUSD))")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(AppTheme.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
            }
            .padding(.top, 5)

            ProgressBar(value: plan.usagePercent)
                .padding(.top, 8)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("已用 \(String(format: "%.1f", plan.usagePercent))%")
                Spacer(minLength: 5)
                Text(SubscriptionEngine.expiryLabel(plan.expiresAt))
            }
            .font(AppTheme.monoMeta)
            .foregroundColor(AppTheme.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.top, 5)

            Text("本周 \(money(plan.weeklyUsageUSD)) · 本月 \(money(plan.monthlyUsageUSD))")
                .font(AppTheme.monoSmall)
                .foregroundColor(AppTheme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.top, 3)
            DividerLine().padding(.top, 8)
        }
    }
}

private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.missing.opacity(0.52))
                Capsule()
                    .fill(value >= 90 ? AppTheme.red : value >= 70 ? AppTheme.amber : AppTheme.green)
                    .frame(width: max(value > 0 ? 2 : 0, geometry.size.width * min(100, max(0, value)) / 100))
            }
        }
        .frame(height: 6)
    }
}

private struct ExtraPanels: View {
    let snapshot: StatusSnapshot
    @ObservedObject var store: StatusStore
    @Binding var diagnosticsExpanded: Bool
    @Binding var eventsExpanded: Bool

    var body: some View {
        let diagnostics = StatusEngine.diagnostics(snapshot, settings: store.notificationSettings)
        if !diagnostics.isEmpty {
            DividerLine().padding(.top, 15)
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(diagnostics) { item in
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
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("诊断 · \(diagnostics.count) 项")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppTheme.primary)
                    Spacer()
                }
            }
            .tint(AppTheme.secondary)
            .padding(.top, 14)
        }
        if !snapshot.customMonitors.isEmpty {
            DividerLine().padding(.top, 15)
            VStack(alignment: .leading, spacing: 8) {
                Text("自定义监测")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.primary)
                ForEach(snapshot.customMonitors) { result in
                    HStack(spacing: 8) {
                        Circle().fill(result.classification == "ok" ? AppTheme.green : AppTheme.red).frame(width: 7, height: 7)
                        Text(result.label).font(AppTheme.monoBody).foregroundColor(AppTheme.primary).lineLimit(1)
                        Spacer(minLength: 5)
                        Text(result.detail).font(AppTheme.monoSmall).foregroundColor(result.classification == "ok" ? AppTheme.secondary : AppTheme.red).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
            .padding(.top, 14)
        }
        let events = Array(StatusEngine.loadEvents().prefix(8))
        if !events.isEmpty {
            DividerLine().padding(.top, 15)
            DisclosureGroup(isExpanded: $eventsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(events) { event in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: event.phase == .opened ? "xmark.octagon.fill" : "checkmark.circle.fill")
                                .foregroundColor(event.phase == .opened ? AppTheme.red : AppTheme.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(event.target) · \(event.phase == .opened ? "异常" : "恢复")").font(AppTheme.monoBody).foregroundColor(AppTheme.primary)
                                Text("\(event.detail) · \(clock(event.date))").font(AppTheme.monoSmall).foregroundColor(AppTheme.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("最近异常事件").font(.system(size: 18, weight: .bold)).foregroundColor(AppTheme.primary)
            }
            .tint(AppTheme.secondary)
            .padding(.top, 14)
        }
    }
}

private struct FooterView: View {
    let snapshot: StatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DividerLine().padding(.top, 17)
            Text("data \(clock(snapshot.generatedAt)) · \(StatusEngine.dataTrustLabel(snapshot)) · 更新 \(clock(snapshot.fetchedAt))")
                .font(AppTheme.monoSmall)
                .foregroundColor(AppTheme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let error = snapshot.lastError {
                Text(error).font(AppTheme.monoSmall).foregroundColor(AppTheme.amber)
            }
        }
    }
}

private struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().tint(AppTheme.green)
            Text(message).font(AppTheme.monoBody).foregroundColor(AppTheme.secondary)
        }
        .padding(.top, 80)
    }
}

private struct DividerLine: View {
    var body: some View { Rectangle().fill(AppTheme.divider).frame(height: 1) }
}
