import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var store: StatusStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var diagnosticsExpanded = true
    @State private var eventsExpanded = false
    @State private var selectedService: ServiceStatus?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderView(showingSettings: $showingSettings)
                    if let snapshot = store.snapshot {
                        GlobalHealthCard(snapshot: snapshot, store: store)
                        StatusOverview(snapshot: snapshot, store: store, selectedService: $selectedService)
                        SubscriptionPanel(store: store, openSettings: { showingSettings = true })
                        CustomMonitorPanel(snapshot: snapshot)
                        ExtraPanels(snapshot: snapshot, store: store,
                                    diagnosticsExpanded: $diagnosticsExpanded,
                                    eventsExpanded: $eventsExpanded,
                                    openSettings: { showingSettings = true })
                        FooterView(snapshot: snapshot, store: store)
                    } else {
                        LoadingView(message: store.lastError ?? "正在读取状态，请稍候…")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await store.refresh(source: "下拉刷新", forceSubscription: true) }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(store: store) }
        .sheet(item: $selectedService) { service in ServiceDetailView(service: service, store: store) }
        .sheet(item: $store.sharePayload) { payload in
            ActivityView(items: [payload.url]).presentationDetents([.medium])
        }
        .alert("操作反馈", isPresented: Binding(get: {
            store.lastActionMessage != nil
        }, set: { visible in
            if !visible { store.lastActionMessage = nil }
        })) {
            Button("好", role: .cancel) { store.lastActionMessage = nil }
        } message: {
            Text(store.lastActionMessage ?? "")
        }
        .onAppear { store.startForegroundLoop() }
        .onChange(of: scenePhase) { phase in store.sceneChanged(phase) }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var store: StatusStore
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI INPUT").font(AppTheme.monoTitle).foregroundColor(AppTheme.green)
                Text(store.sourceLabel).font(.subheadline).foregroundColor(AppTheme.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(store.gatewayLabel)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(store.snapshot?.gateway?.classification == .ok ? AppTheme.green : AppTheme.amber)
                if store.isRefreshing { ProgressView().controlSize(.small).tint(AppTheme.green) }
            }
            Button {
                Task { await store.refresh(source: "立即刷新", forceSubscription: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(AppTheme.green)
            .disabled(store.isRefreshing)
            .accessibilityLabel("立即刷新状态")
            .accessibilityHint("读取模型、网关和额度数据")
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(AppTheme.secondary)
            .accessibilityLabel("打开设置")
        }
    }
}

private struct GlobalHealthCard: View {
    let snapshot: StatusSnapshot
    @ObservedObject var store: StatusStore

    private var hasData: Bool { snapshot.services.contains { $0.last != nil } }
    private var isAllHealthy: Bool { store.configuredCount > 0 && store.issueCount == 0 && store.waitingCount == 0 && store.staleCount == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundColor(statusColor)
                Text(store.statusHeadline)
                    .font(.title3.weight(.bold))
                    .foregroundColor(AppTheme.primary)
                Spacer()
                Text("\(store.onlineCount)/\(store.configuredCount)")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundColor(statusColor)
                Text("正常").font(.subheadline).foregroundColor(AppTheme.secondary)
            }
            if store.configuredCount == 0 {
                Text("还没有启用模型。打开设置添加模型后，点击立即刷新。")
                    .font(.body).foregroundColor(AppTheme.secondary)
            } else if !hasData {
                Text("已配置 \(store.configuredCount) 个模型，等待首次有效采样。")
                    .font(.body).foregroundColor(AppTheme.secondary)
            } else {
                HStack(spacing: 14) {
                    SummaryBadge(title: "异常", value: store.issueCount, color: store.issueCount > 0 ? AppTheme.red : AppTheme.green)
                    SummaryBadge(title: "待检测", value: store.waitingCount, color: store.waitingCount > 0 ? AppTheme.amber : AppTheme.secondary)
                    SummaryBadge(title: "过期", value: store.staleCount, color: store.staleCount > 0 ? AppTheme.amber : AppTheme.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Divider().overlay(AppTheme.divider.opacity(0.7))
            HStack(alignment: .firstTextBaseline) {
                Text("数据来源").font(.subheadline).foregroundColor(AppTheme.secondary)
                Text(store.sourceLabel).font(.subheadline.weight(.medium)).foregroundColor(AppTheme.primary)
                Spacer()
                Text("更新 \(clock(snapshot.fetchedAt))").font(.subheadline).foregroundColor(AppTheme.secondary)
            }
            if let error = snapshot.lastError {
                Text(error).font(.subheadline).foregroundColor(AppTheme.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(AppTheme.card)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(statusColor.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(store.statusHeadline)，\(store.onlineCount) 个模型正常，共配置 \(store.configuredCount) 个，数据来源 \(store.sourceLabel)")
    }

    private var statusColor: Color {
        if store.configuredCount == 0 || !hasData { return AppTheme.amber }
        return isAllHealthy ? AppTheme.green : AppTheme.red
    }
    private var iconName: String {
        if store.configuredCount == 0 || !hasData { return "hourglass.circle.fill" }
        return isAllHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }
}

private struct SummaryBadge: View {
    let title: String
    let value: Int
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(.title3, design: .monospaced).weight(.bold)).foregroundColor(color)
            Text(title).font(.subheadline).foregroundColor(AppTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusOverview: View {
    let snapshot: StatusSnapshot
    @ObservedObject var store: StatusStore
    @Binding var selectedService: ServiceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("模型状态").font(.title2.weight(.bold)).foregroundColor(AppTheme.primary)
                    Text("\(store.historyRange.fullLabel) · \(StatusEngine.dataTrustLabel(snapshot))")
                        .font(.subheadline).foregroundColor(AppTheme.secondary)
                }
                Spacer()
                Menu {
                    ForEach(ServiceSort.allCases) { sort in
                        Button {
                            store.serviceSort = sort
                        } label: {
                            Label(sort.label, systemImage: store.serviceSort == sort ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 76, minHeight: 44)
                }
                .foregroundColor(AppTheme.green)
                .accessibilityLabel("排序，当前\(store.serviceSort.label)")
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(AppTheme.secondary)
                TextField("搜索模型名称", text: $store.searchText)
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppTheme.secondary)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(AppTheme.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("筛选").font(.headline).foregroundColor(AppTheme.primary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DiagnosticFilter.allCases) { filter in
                        FilterChip(filter: filter, count: store.filterCount(filter), selected: store.diagnosticFilter == filter) {
                            store.diagnosticFilter = filter
                        }
                    }
                }
            }
            .accessibilityLabel("状态筛选")

            HStack {
                Text("分组").font(.headline).foregroundColor(AppTheme.primary)
                Spacer()
                Text("\(store.visibleServices.count) 项结果").font(.subheadline).foregroundColor(AppTheme.secondary)
            }
            Picker("分组方式", selection: $store.serviceGrouping) {
                ForEach(ServiceGrouping.allCases) { grouping in Text(grouping.label).tag(grouping) }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .accessibilityLabel("分组方式")

            if store.visibleServices.isEmpty {
                EmptyFilterState(store: store)
            } else {
                ForEach(store.groupedServices) { group in
                    if store.serviceGrouping != .model {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").foregroundColor(AppTheme.amber)
                            Text(group.name).font(.headline).foregroundColor(AppTheme.amber)
                            Text("\(group.services.count)").font(.subheadline).foregroundColor(AppTheme.secondary)
                        }
                        .padding(.top, 4)
                    }
                    ForEach(group.services) { service in
                        ServiceCard(service: service, range: store.historyRange,
                                    refresh: { Task { await store.refreshModel(service) } },
                                    open: { selectedService = service })
                    }
                }
            }

            HistoryRangePicker(selection: $store.historyRange)
            ChartLegend()
        }
    }
}

private struct FilterChip: View {
    let filter: DiagnosticFilter
    let count: Int
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: filter.icon).font(.caption)
                Text("\(filter.label) \(count)").font(.subheadline.weight(selected ? .bold : .regular))
            }
            .foregroundColor(selected ? AppTheme.background : AppTheme.primary)
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .background(selected ? AppTheme.green : AppTheme.controlBackground)
            .overlay(Capsule().stroke(selected ? AppTheme.green : AppTheme.divider, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(filter.label)，\(count) 个")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct EmptyFilterState: View {
    @ObservedObject var store: StatusStore
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: store.searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                .font(.system(size: 32)).foregroundColor(AppTheme.secondary)
            Text(store.searchText.isEmpty ? "当前筛选没有匹配的模型" : "没有找到匹配模型")
                .font(.headline).foregroundColor(AppTheme.primary)
            Text("已配置 \(store.configuredCount) 个模型；可以清除筛选或搜索条件。")
                .font(.subheadline).foregroundColor(AppTheme.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if store.diagnosticFilter != .all {
                    Button("清除筛选") { store.diagnosticFilter = .all }
                        .buttonStyle(BorderedActionButtonStyle())
                }
                if !store.searchText.isEmpty {
                    Button("清除搜索") { store.searchText = "" }
                        .buttonStyle(BorderedActionButtonStyle(color: AppTheme.secondary))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(AppTheme.controlBackground.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryRangePicker: View {
    @Binding var selection: HistoryRange
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("历史窗口").font(.headline).foregroundColor(AppTheme.primary)
            HStack(spacing: 8) {
                ForEach(HistoryRange.allCases, id: \.self) { range in
                    Button { selection = range } label: {
                        Text(range.fullLabel)
                            .font(.subheadline.weight(selection == range ? .bold : .regular))
                            .foregroundColor(selection == range ? AppTheme.background : AppTheme.primary)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(selection == range ? AppTheme.green : AppTheme.controlBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("历史窗口\(range.fullLabel)")
                    .accessibilityAddTraits(selection == range ? .isSelected : [])
                }
            }
        }
    }
}

private struct ServiceCard: View {
    let service: ServiceStatus
    let range: HistoryRange
    let refresh: () -> Void
    let open: () -> Void

    private var state: ServiceState { StatusEngine.serviceState(service) }
    private var summary: HistorySummary { StatusEngine.historySummary(service, range: range) }
    private var stats: LatencyStats { StatusEngine.latencyStats(service, range: range) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        Image(systemName: stateIcon(state)).foregroundColor(stateColor(state))
                        Text(service.model).font(AppTheme.monoModel).foregroundColor(AppTheme.primary)
                            .lineLimit(1).minimumScaleFactor(0.72)
                        Text(stateText(state)).font(.headline).foregroundColor(stateColor(state))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.title3).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.green)
                .accessibilityLabel("重新检测\(service.model)")
            }
            HStack(spacing: 8) {
                MetricBlock(title: "当前延迟", value: service.last?.latencyMS.map { "\($0) ms" } ?? "--")
                MetricBlock(title: "官方可用率", value: percent(service.uptimePercent))
                MetricBlock(title: "\(range.label)成功率", value: percent(summary.successRate))
            }
            HStack(spacing: 8) {
                MetricBlock(title: "已采样", value: "\(summary.observed)/\(range.rawValue)")
                MetricBlock(title: "未采样", value: "\(summary.missing) 分钟")
                MetricBlock(title: "p95", value: stats.p95.map { "\($0) ms" } ?? "--")
            }
            LatencyTrend(service: service, range: range)
            HistoryBar(summary: summary)
        }
        .padding(15)
        .background(AppTheme.card)
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(stateColor(state).opacity(0.28), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(service.model)，\(stateText(state))，当前延迟\(service.last?.latencyMS.map { "\($0) 毫秒" } ?? "暂无")")
    }

    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "--" }
}

private struct MetricBlock: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundColor(AppTheme.secondary).lineLimit(1).minimumScaleFactor(0.75)
            Text(value).font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundColor(AppTheme.primary)
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LatencyTrend: View {
    let service: ServiceStatus
    let range: HistoryRange
    private var values: [Int] { StatusEngine.latencyValues(service, range: range) }
    private var stats: LatencyStats { StatusEngine.latencyStats(service, range: range) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("延迟趋势", systemImage: "chart.bar.xaxis")
                    .font(.subheadline).foregroundColor(AppTheme.secondary)
                Spacer()
                Text("\(values.count) 个采样 · p95 \(stats.p95.map { "\($0) ms" } ?? "--")")
                    .font(.caption).foregroundColor(AppTheme.secondary)
            }
            if values.isEmpty {
                Text("暂无延迟采样（灰色表示未采样，不等于失败）")
                    .font(.caption).foregroundColor(AppTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 30)
            } else {
                GeometryReader { geometry in
                    let maximum = CGFloat(max(values.max() ?? 1, 1))
                    HStack(alignment: .bottom, spacing: values.count > 120 ? 0.5 : 1) {
                        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AppTheme.green.opacity(0.78))
                                .frame(height: max(3, geometry.size.height * CGFloat(value) / maximum))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 42)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("延迟趋势，共\(values.count)个采样，p95 \(stats.p95.map { "\($0) 毫秒" } ?? "暂无")")
    }
}

private struct HistoryBar: View {
    let summary: HistorySummary
    var body: some View {
        GeometryReader { geometry in
            let count = max(1, summary.slots.count)
            let gap: CGFloat = count > 120 ? 0.45 : 1
            let width = max(0.5, (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(spacing: gap) {
                ForEach(Array(summary.slots.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(value == true ? AppTheme.green : value == false ? AppTheme.red : AppTheme.missing)
                        .frame(width: width, height: value == nil ? 8 : 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .clipped()
        }
        .frame(height: 20)
        .accessibilityLabel("历史采样：成功\(summary.succeeded)分钟，失败\(summary.failed)分钟，未采样\(summary.missing)分钟")
    }
}

private struct ChartLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            LegendItem(color: AppTheme.green, title: "成功")
            LegendItem(color: AppTheme.red, title: "失败")
            LegendItem(color: AppTheme.missing, title: "未采样")
            LegendItem(color: AppTheme.amber, title: "过期/未知")
        }
        .font(.caption)
        .foregroundColor(AppTheme.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("图表图例：绿色成功，红色失败，灰色未采样，黄色过期或未知")
    }
}

private struct LegendItem: View {
    let color: Color
    let title: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }
}

private struct SubscriptionPanel: View {
    @ObservedObject var store: StatusStore
    let openSettings: () -> Void
    private var plans: [SubscriptionPlan] { SubscriptionEngine.sortedPlans(store.subscription?.plans ?? []).filter { $0.isActive() } }
    private var summary: SubscriptionSummary { SubscriptionEngine.summary(plans) }
    private var health: SubscriptionHealth { SubscriptionEngine.health(store.subscription, tokenConfigured: store.tokenConfigured, error: store.subscriptionError) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("订阅额度", systemImage: "creditcard.fill").font(.title3.weight(.bold)).foregroundColor(AppTheme.primary)
                Spacer()
                Text(SubscriptionEngine.healthLabel(health)).font(.subheadline.weight(.medium)).foregroundColor(healthColor)
            }
            if plans.isEmpty {
                Text(emptyText).font(.body).foregroundColor(AppTheme.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: openSettings) {
                    Label(store.tokenConfigured ? "刷新或检查额度" : "配置订阅 Token", systemImage: store.tokenConfigured ? "arrow.clockwise" : "key")
                }
                .buttonStyle(BorderedActionButtonStyle())
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("今日总剩余").font(.body).foregroundColor(AppTheme.secondary)
                    Spacer()
                    Text("\(money(summary.totalRemainingUSD)) / \(money(summary.totalLimitUSD))")
                        .font(.system(.title3, design: .monospaced).weight(.bold)).foregroundColor(AppTheme.green)
                }
                Text("\(summary.activePlans) 个有效套餐 · \(SubscriptionEngine.resetLabel()) · \(SubscriptionEngine.freshnessLabel(store.subscription))")
                    .font(.subheadline).foregroundColor(AppTheme.secondary)
                ForEach(plans) { plan in PlanRow(plan: plan) }
            }
            if let error = store.subscriptionError {
                Text(error).font(.subheadline).foregroundColor(AppTheme.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var emptyText: String {
        if !store.tokenConfigured { return "尚未配置额度 Token。Widget 会明确显示未配置，不会显示虚假的 0。" }
        return "暂时没有可显示的有效套餐，或额度接口正在读取。"
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plan.name).font(.headline).foregroundColor(AppTheme.primary)
                Spacer()
                Text("剩余 \(money(plan.remainingUSD))").font(.system(.subheadline, design: .monospaced).weight(.bold)).foregroundColor(AppTheme.green)
            }
            ProgressView(value: min(1, max(0, plan.usagePercent / 100)))
                .tint(plan.usagePercent >= 90 ? AppTheme.red : plan.usagePercent >= 70 ? AppTheme.amber : AppTheme.green)
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
            HStack {
                Text("今日已用 \(String(format: "%.1f", plan.usagePercent))%")
                Spacer()
                Text(SubscriptionEngine.expiryLabel(plan.expiresAt))
            }
            .font(.subheadline).foregroundColor(AppTheme.secondary)
            Text("每日 \(money(plan.dailyUsageUSD)) / \(money(plan.dailyLimitUSD)) · 本周 \(money(plan.weeklyUsageUSD)) · 本月 \(money(plan.monthlyUsageUSD))")
                .font(.caption).foregroundColor(AppTheme.secondary)
        }
        .padding(.top, 3)
    }
}

private struct CustomMonitorPanel: View {
    let snapshot: StatusSnapshot
    var body: some View {
        if snapshot.customMonitors.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("自定义监测", systemImage: "network")
                        .font(.title3.weight(.bold)).foregroundColor(AppTheme.primary)
                    Spacer()
                    Text("\(snapshot.customMonitors.count) 项").font(.subheadline).foregroundColor(AppTheme.secondary)
                }
                ForEach(snapshot.customMonitors) { monitor in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: monitor.classification == "ok" ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundColor(monitor.classification == "ok" ? AppTheme.green : AppTheme.red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(monitor.label).font(.body.weight(.semibold)).foregroundColor(AppTheme.primary)
                            Text(monitor.detail).font(.subheadline).foregroundColor(AppTheme.secondary)
                        }
                        Spacer()
                        if let latency = monitor.latencyMS { Text("\(latency) ms").font(.system(.caption, design: .monospaced)).foregroundColor(AppTheme.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }
}

private struct ExtraPanels: View {
    let snapshot: StatusSnapshot
    @ObservedObject var store: StatusStore
    @Binding var diagnosticsExpanded: Bool
    @Binding var eventsExpanded: Bool
    let openSettings: () -> Void
    @State private var technical = Set<String>()

    var body: some View {
        let diagnostics = StatusEngine.diagnostics(snapshot, settings: store.notificationSettings)
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if diagnostics.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(AppTheme.green)
                            Text("当前没有发现需要处理的问题").font(.body).foregroundColor(AppTheme.primary)
                        }
                    } else {
                        ForEach(diagnostics) { item in
                            DiagnosticCard(item: item,
                                           expanded: technical.contains(item.id),
                                           toggle: {
                                               if technical.contains(item.id) { technical.remove(item.id) } else { technical.insert(item.id) }
                                           },
                                           refresh: { Task { await store.refresh(source: "诊断修复", forceSubscription: true) } },
                                           openSettings: openSettings,
                                           copy: {
                                               UIPasteboard.general.string = item.technicalDetail ?? item.detail
                                               store.lastActionMessage = "技术详情已复制"
                                           })
                        }
                    }
                    VStack(spacing: 10) {
                        Button { store.copyDiagnosticReport() } label: { Label("复制完整诊断报告", systemImage: "doc.on.clipboard") }
                            .buttonStyle(BorderedActionButtonStyle())
                        HStack(spacing: 10) {
                            Button { store.export(format: .json) } label: { Label("导出 JSON", systemImage: "curlybraces") }
                                .buttonStyle(BorderedActionButtonStyle())
                            Button { store.export(format: .csv) } label: { Label("导出 CSV", systemImage: "tablecells") }
                                .buttonStyle(BorderedActionButtonStyle(color: AppTheme.secondary))
                        }
                    }
                }
                .padding(.top, 12)
            } label: {
                Label("诊断与修复 · \(diagnostics.count) 项", systemImage: diagnostics.isEmpty ? "checkmark.seal" : "stethoscope")
                    .font(.title3.weight(.bold)).foregroundColor(AppTheme.primary)
                    .frame(minHeight: 46, alignment: .leading)
            }
            .tint(AppTheme.secondary)

            let events = Array(StatusEngine.loadEvents().prefix(12))
            DisclosureGroup(isExpanded: $eventsExpanded) {
                VStack(alignment: .leading, spacing: 11) {
                    if events.isEmpty {
                        Text("暂无异常或恢复事件").font(.body).foregroundColor(AppTheme.secondary)
                    } else {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: event.phase == .opened ? "xmark.octagon.fill" : "checkmark.circle.fill")
                                    .foregroundColor(event.phase == .opened ? AppTheme.red : AppTheme.green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(event.target) · \(event.phase == .opened ? "异常" : "恢复")")
                                        .font(.body.weight(.semibold)).foregroundColor(AppTheme.primary)
                                    Text("\(event.detail) · \(clock(event.date))")
                                        .font(.subheadline).foregroundColor(AppTheme.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Label("最近异常事件", systemImage: "clock.arrow.circlepath")
                    .font(.title3.weight(.bold)).foregroundColor(AppTheme.primary)
                    .frame(minHeight: 46, alignment: .leading)
            }
            .tint(AppTheme.secondary)
        }
    }
}

private struct DiagnosticCard: View {
    let item: DiagnosticItem
    let expanded: Bool
    let toggle: () -> Void
    let refresh: () -> Void
    let openSettings: () -> Void
    let copy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.severity == .failure ? "xmark.octagon.fill" : item.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.title3).foregroundColor(item.severity == .failure ? AppTheme.red : AppTheme.amber)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.title).font(.body.weight(.semibold)).foregroundColor(AppTheme.primary)
                Text(item.detail).font(.subheadline).foregroundColor(AppTheme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: repairAction) {
                        Text(repairLabel).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 11).frame(minHeight: 40)
                            .background(AppTheme.green.opacity(0.12)).clipShape(Capsule())
                    }
                    .buttonStyle(.plain).foregroundColor(AppTheme.green)
                    if item.technicalDetail != nil {
                        Button(action: toggle) {
                            Text(expanded ? "收起详情" : "技术详情").font(.subheadline)
                                .padding(.horizontal, 9).frame(minHeight: 40)
                        }
                        .buttonStyle(.plain).foregroundColor(AppTheme.secondary)
                        Button(action: copy) {
                            Image(systemName: "doc.on.clipboard").frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain).foregroundColor(AppTheme.secondary)
                        .accessibilityLabel("复制技术详情")
                    }
                }
                if expanded, let detail = item.technicalDetail {
                    Text(detail).font(.system(.footnote, design: .monospaced)).foregroundColor(AppTheme.amber)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(10).background(AppTheme.controlBackground).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(12)
        .background(AppTheme.controlBackground.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var repairLabel: String {
        switch item.repair {
        case .refresh: return "重新检测"
        case .configureModels: return "打开模型设置"
        case .configureToken: return "打开额度设置"
        case .none: return "知道了"
        }
    }
    private func repairAction() {
        switch item.repair {
        case .refresh: refresh()
        case .configureModels, .configureToken: openSettings()
        case .none: break
        }
    }
}

private struct ServiceDetailView: View {
    let service: ServiceStatus
    @ObservedObject var store: StatusStore
    @Environment(\.dismiss) private var dismiss

    private var config: ModelMonitor? { store.modelMonitors.first { $0.model == service.model } }
    private var state: ServiceState { StatusEngine.serviceState(service) }
    private var stats: LatencyStats { StatusEngine.latencyStats(service, range: store.historyRange) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 9) {
                        Image(systemName: stateIcon(state)).font(.title2).foregroundColor(stateColor(state))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(service.model).font(AppTheme.monoModel).foregroundColor(AppTheme.primary)
                            Text(stateText(state)).font(.headline).foregroundColor(stateColor(state))
                        }
                        Spacer()
                    }
                    Button { Task { await store.refreshModel(service) } } label: {
                        Label("重新检测此模型", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(FilledActionButtonStyle())
                    DetailSection(title: "模型与账号") {
                        DetailRow(title: "供应商", value: config?.provider.isEmpty == false ? config!.provider : "未标注")
                        DetailRow(title: "账号", value: config?.account.isEmpty == false ? config!.account : "未标注")
                        DetailRow(title: "监测状态", value: config?.enabled == true ? "已启用" : "已停用")
                        DetailRow(title: "忽略 / 维护", value: config?.isMuted == true ? "已忽略" : config?.isInMaintenance == true ? "维护中" : "无")
                    }
                    DetailSection(title: "当前数据") {
                        DetailRow(title: "状态", value: stateText(state))
                        DetailRow(title: "当前延迟", value: service.last?.latencyMS.map { "\($0) ms" } ?? "暂无")
                        DetailRow(title: "官方可用率", value: service.uptimePercent.map { String(format: "%.1f%%", $0) } ?? "暂无")
                        DetailRow(title: "最后探测", value: clock(service.last?.timestamp))
                    }
                    DetailSection(title: "\(store.historyRange.fullLabel)统计") {
                        let summary = StatusEngine.historySummary(service, range: store.historyRange)
                        DetailRow(title: "采样情况", value: "成功 \(summary.succeeded) · 失败 \(summary.failed) · 未采样 \(summary.missing)")
                        DetailRow(title: "成功率", value: summary.successRate.map { String(format: "%.1f%%", $0) } ?? "暂无")
                        DetailRow(title: "延迟", value: "p50 \(stats.median.map(String.init) ?? "--") · p95 \(stats.p95.map(String.init) ?? "--") · 最大 \(stats.maximum.map(String.init) ?? "--") ms")
                    }
                    if let error = service.last?.error {
                        DetailSection(title: "当前问题") {
                            Text(error).font(.system(.footnote, design: .monospaced)).foregroundColor(AppTheme.red)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(ServiceIssue.from(error).recommendation).font(.subheadline).foregroundColor(AppTheme.secondary)
                        }
                    }
                    if let backup = store.backup(for: service) {
                        DetailSection(title: "备用模型建议") {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(AppTheme.amber)
                                Text("建议尝试 \(backup.model)").font(.body.weight(.semibold)).foregroundColor(AppTheme.primary)
                                Spacer()
                                Text(backup.last?.latencyMS.map { "\($0) ms" } ?? "暂无")
                                    .font(.system(.subheadline, design: .monospaced)).foregroundColor(AppTheme.secondary)
                            }
                            Text("仅提供建议，不会自动修改外部客户端配置。")
                                .font(.subheadline).foregroundColor(AppTheme.secondary)
                        }
                    }
                    Button { store.copyDiagnosticReport(for: service) } label: {
                        Label("复制此模型完整诊断", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(BorderedActionButtonStyle())
                }
                .padding(18)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("模型详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }.frame(minWidth: 54, minHeight: 44)
                }
            }
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundColor(AppTheme.primary)
            content()
        }
        .padding(14)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline).foregroundColor(AppTheme.secondary)
            Text(value).font(.body).foregroundColor(AppTheme.primary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct FooterView: View {
    let snapshot: StatusSnapshot
    @ObservedObject var store: StatusStore
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(AppTheme.divider)
            Text("生成 \(clock(snapshot.generatedAt)) · \(StatusEngine.dataTrustLabel(snapshot)) · 更新 \(clock(snapshot.fetchedAt))")
                .font(.caption).foregroundColor(AppTheme.secondary)
            Text("前台自动刷新约每分钟一次；后台刷新由 iOS 调度，非实时保证。")
                .font(.caption).foregroundColor(AppTheme.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct LoadingView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView().tint(AppTheme.green)
            Text(message).font(.body).foregroundColor(AppTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 80)
    }
}
