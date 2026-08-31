import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var store: StatusStore
    @Environment(\.dismiss) private var dismiss
    @State private var logCategories: Set<AppLogCategory> = Set(AppLogCategory.allCases)
    @State private var logRange: AppLogRange = .week
    @State private var logFormat: AppLogFormat = .text
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSection(title: "订阅额度", icon: "creditcard.fill") {
                        HStack {
                            Label(store.tokenConfigured ? "Token 已配置" : "未配置 Token", systemImage: store.tokenConfigured ? "checkmark.shield.fill" : "key")
                                .font(.body.weight(.semibold))
                                .foregroundColor(store.tokenConfigured ? AppTheme.green : AppTheme.amber)
                            Spacer()
                            Text(subscriptionStatus).font(.subheadline).foregroundColor(AppTheme.secondary)
                        }
                        SecureField("粘贴 Token（支持 Bearer 前缀）", text: $store.tokenDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.body)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 50)
                            .background(AppTheme.controlBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button { store.pasteToken() } label: {
                            Label("从剪贴板粘贴 Token", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(BorderedActionButtonStyle())
                        Button { Task { await store.saveToken() } } label: {
                            Label(store.subscriptionRefreshing ? "正在读取额度…" : "保存并读取额度", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(FilledActionButtonStyle())
                        .disabled(store.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.subscriptionRefreshing)
                        if store.tokenConfigured {
                            Button { Task { await store.refreshSubscription() } } label: {
                                Label(store.subscriptionRefreshing ? "正在刷新…" : "刷新额度", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(BorderedActionButtonStyle())
                            .disabled(store.subscriptionRefreshing)
                            Button(role: .destructive) { store.removeToken() } label: {
                                Label("删除设备上的 Token", systemImage: "key.slash")
                            }
                            .buttonStyle(BorderedActionButtonStyle(color: AppTheme.red))
                        }
                        if let error = store.subscriptionError {
                            FeedbackText(text: error, color: AppTheme.amber)
                        }
                        Text("Token 只保存于本机 Keychain；不会写入 Widget 或导出日志。")
                            .font(.subheadline).foregroundColor(AppTheme.secondary)
                    }

                    SettingsSection(title: "模型与账号", icon: "cpu") {
                        if store.modelMonitors.isEmpty {
                            Text("尚未配置模型").font(.body).foregroundColor(AppTheme.secondary)
                        } else {
                            ForEach($store.modelMonitors) { $model in
                                ModelEditor(model: $model, store: store)
                            }
                            .onDelete { offsets in store.deleteModelMonitors(at: offsets) }
                        }
                        Button { store.addModelMonitor() } label: {
                            Label("添加模型", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(BorderedActionButtonStyle())
                        .disabled(store.modelMonitors.count >= 50)
                        Button { store.resetDefaultModels() } label: {
                            Label("恢复默认模型列表", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(BorderedActionButtonStyle(color: AppTheme.secondary))
                        Text("模型名称不能为空且不能重复。忽略/维护只影响提醒，不会修改外部客户端配置。")
                            .font(.subheadline).foregroundColor(AppTheme.secondary)
                    }

                    SettingsSection(title: "Widget 显示", icon: "rectangle.grid.2x2.fill") {
                        Picker("显示模型", selection: Binding(get: {
                            store.widgetModelSelection
                        }, set: { value in
                            store.setWidgetModelSelection(value)
                        })) {
                            Text("全部模型").tag(WidgetModelSelection.all.rawValue)
                            ForEach(store.configuredModels) { model in
                                Text(model.model).tag(model.model)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        Text("支持小号、中号和大号 Widget。选择会立即同步到 Widget；首次显示前请打开 App 完成一次刷新。")
                            .font(.subheadline).foregroundColor(AppTheme.secondary)
                    }

                    SettingsSection(title: "通知", icon: "bell.fill") {
                        SettingToggle(title: "状态异常提醒", isOn: boolBinding(\.enabled))
                        SettingToggle(title: "恢复提醒", isOn: boolBinding(\.recoveryEnabled))
                        SettingToggle(title: "网关延迟提醒", isOn: boolBinding(\.gatewayEnabled))
                        SettingToggle(title: "每日额度提醒", isOn: boolBinding(\.subscriptionQuotaEnabled))
                        SettingToggle(title: "订阅到期提醒", isOn: boolBinding(\.subscriptionExpiryEnabled))
                        SettingPicker(title: "连续失败阈值", selection: intBinding(\.failureMinutes), options: [2, 5, 10], suffix: "分钟")
                        SettingPicker(title: "网关延迟阈值", selection: intBinding(\.gatewayThresholdMS), options: [1000, 1500, 3000], suffix: "ms")
                        SettingPicker(title: "额度提醒阈值", selection: intBinding(\.subscriptionQuotaThreshold), options: [70, 85, 95], suffix: "%")
                        Button { Task { await store.requestNotificationPermission() } } label: {
                            Label("请求系统通知权限", systemImage: "bell.badge")
                        }
                        .buttonStyle(BorderedActionButtonStyle())
                        Button { Task { await store.sendTestNotification() } } label: {
                            Label("发送测试通知", systemImage: "paperplane")
                        }
                        .buttonStyle(BorderedActionButtonStyle(color: AppTheme.secondary))
                        Text("iOS 后台任务由系统调度，通知时间不是固定定时器。")
                            .font(.subheadline).foregroundColor(AppTheme.secondary)
                    }

                    SettingsSection(title: "自定义 HTTPS 监测 · \(store.monitors.count)/20", icon: "network") {
                        ForEach($store.monitors) { $monitor in
                            MonitorEditor(monitor: $monitor, store: store)
                        }
                        .onDelete { offsets in store.deleteMonitor(at: offsets) }
                        Button { store.addMonitor() } label: {
                            Label("添加 HTTPS 监测", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(BorderedActionButtonStyle())
                        .disabled(store.monitors.count >= 20)
                    }

                    SettingsSection(title: "后台链路", icon: "server.rack") {
                        HStack {
                            Text("服务状态").font(.body).foregroundColor(AppTheme.secondary)
                            Spacer()
                            Text(store.pluginHealthLabel).font(.body.weight(.semibold)).foregroundColor(backendColor)
                        }
                        if let plugin = store.pluginStatus {
                            BackendMetric(title: "累计请求", value: "\(plugin.attempts) 次")
                            BackendMetric(title: "成功 / 失败", value: "\(plugin.successes) / \(plugin.failures)")
                            BackendMetric(title: "最近成功", value: clock(plugin.lastSuccessDate))
                            BackendMetric(title: "最近间隔", value: plugin.lastInterval > 0 ? String(format: "%.1f 秒", plugin.lastInterval) : "--")
                            BackendMetric(title: "后台日志", value: "\(store.backendLogs.count) 条")
                            if let error = plugin.lastError { FeedbackText(text: error, color: AppTheme.amber) }
                        } else {
                            Text("未连接 RootHide DEB。App 会回退到公共 API；更新配套 DEB 后可使用日志和清零功能。")
                                .font(.body).foregroundColor(AppTheme.secondary)
                        }
                        Button { Task { await store.refreshBackendInfo() } } label: {
                            Label("刷新后台信息", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(BorderedActionButtonStyle())
                        Button { showingClearConfirmation = true } label: {
                            Label("清理后台请求次数", systemImage: "trash.slash")
                        }
                        .buttonStyle(BorderedActionButtonStyle(color: AppTheme.red))
                        Text("清零只重置后台累计请求/成功/失败计数，不会删除当前状态缓存。")
                            .font(.subheadline).foregroundColor(AppTheme.secondary)
                    }

                    SettingsSection(title: "导出日志", icon: "doc.text.magnifyingglass") {
                        Text("选择要包含的日志类型").font(.headline).foregroundColor(AppTheme.primary)
                        ForEach(AppLogCategory.allCases) { category in
                            LogCategoryToggle(category: category, isOn: Binding(get: {
                                logCategories.contains(category)
                            }, set: { enabled in
                                if enabled { logCategories.insert(category) } else { logCategories.remove(category) }
                            }))
                        }
                        SettingPicker(title: "时间范围", selection: Binding(get: {
                            logRange
                        }, set: { logRange = $0 }), options: AppLogRange.allCases, label: { $0.label })
                        SettingPicker(title: "导出格式", selection: Binding(get: {
                            logFormat
                        }, set: { logFormat = $0 }), options: AppLogFormat.allCases, label: { $0.label })
                        Button {
                            Task { await store.exportLogs(categories: logCategories, range: logRange, format: logFormat) }
                        } label: {
                            Label("按选择导出日志", systemImage: "square.and.arrow.up.fill")
                        }
                        .buttonStyle(FilledActionButtonStyle())
                        Text("日志可能包含模型名称、错误文本和时间信息；Token、密码等敏感凭据不会写入日志。")
                            .font(.subheadline).foregroundColor(AppTheme.secondary)
                    }

                    SettingsSection(title: "最近异常事件", icon: "clock.arrow.circlepath") {
                        let events = StatusEngine.loadEvents().prefix(20)
                        if events.isEmpty {
                            Text("暂无异常或恢复事件").font(.body).foregroundColor(AppTheme.secondary)
                        } else {
                            ForEach(Array(events)) { event in
                                HStack(alignment: .top, spacing: 10) {
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

                    SettingsSection(title: "关于", icon: "info.circle.fill") {
                        BackendMetric(title: "应用版本", value: "3.6.0 native")
                        BackendMetric(title: "系统要求", value: "iOS 16.1+")
                        BackendMetric(title: "Widget", value: "小号 / 中号 / 大号")
                        BackendMetric(title: "后台刷新", value: "iOS 调度 + RootHide DEB")
                        Link("打开 AI INPUT 官网", destination: gatewayEndpoint)
                            .font(.body.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }.frame(minWidth: 60, minHeight: 44)
                }
            }
            .confirmationDialog("确定清理后台请求次数？", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
                Button("清理次数", role: .destructive) { Task { await store.clearBackendCounters() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会将后台累计请求、成功、失败和最近时间重置为零；状态缓存会保留。")
            }
            .onAppear { Task { await store.refreshBackendInfo() } }
        }
    }

    private var subscriptionStatus: String {
        guard let value = store.subscription else { return store.tokenConfigured ? "等待读取" : "未配置" }
        return SubscriptionEngine.healthLabel(SubscriptionEngine.health(value, tokenConfigured: store.tokenConfigured, error: store.subscriptionError))
    }
    private var backendColor: Color {
        switch store.pluginHealth {
        case .healthy: return AppTheme.green
        case .stale, .starting: return AppTheme.amber
        default: return AppTheme.red
        }
    }
    private func boolBinding(_ keyPath: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.notificationSettings[keyPath: keyPath] }, set: { value in
            var settings = store.notificationSettings
            settings[keyPath: keyPath] = value
            store.updateNotificationSettings(settings)
            if value { Task { await store.requestNotificationPermission() } }
        })
    }
    private func intBinding(_ keyPath: WritableKeyPath<NotificationSettings, Int>) -> Binding<Int> {
        Binding(get: { store.notificationSettings[keyPath: keyPath] }, set: { value in
            var settings = store.notificationSettings
            settings[keyPath: keyPath] = value
            store.updateNotificationSettings(settings)
        })
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.title3.weight(.bold)).foregroundColor(AppTheme.primary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn)
            .font(.body)
            .frame(minHeight: 48)
            .tint(AppTheme.green)
    }
}

private struct SettingPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let suffix: String?
    let label: (Value) -> String

    init(title: String, selection: Binding<Value>, options: [Value], suffix: String? = nil) {
        self.title = title; self._selection = selection; self.options = options; self.suffix = suffix
        self.label = { value in suffix.map { "\(value)\($0)" } ?? "\(value)" }
    }
    init(title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title; self._selection = selection; self.options = options; self.suffix = nil; self.label = label
    }
    var body: some View {
        HStack {
            Text(title).font(.body).foregroundColor(AppTheme.primary)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { value in Text(label(value)).tag(value) }
            }
            .pickerStyle(.menu)
            .font(.body.weight(.semibold))
            .frame(minHeight: 44)
        }
    }
}

private struct ModelEditor: View {
    @Binding var model: ModelMonitor
    @ObservedObject var store: StatusStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模型配置").font(.headline).foregroundColor(AppTheme.primary)
                Spacer()
                Toggle("启用", isOn: $model.enabled).labelsHidden().tint(AppTheme.green)
            }
            LabeledField(title: "模型名称", placeholder: "例如 gpt-5.6-sol", text: $model.model)
            LabeledField(title: "供应商", placeholder: "Input", text: $model.provider)
            LabeledField(title: "账号", placeholder: "默认账号", text: $model.account)
            HStack(spacing: 8) {
                Button(model.isMuted ? "取消忽略" : "忽略 8 小时") {
                    if model.isMuted { model.mutedUntil = nil; store.updateModelMonitors(store.modelMonitors) } else { store.muteModel(model) }
                }
                .buttonStyle(BorderedActionButtonStyle())
                Button(model.isInMaintenance ? "取消维护" : "维护 2 小时") {
                    if model.isInMaintenance { store.clearMaintenance(model) } else { store.maintenanceModel(model) }
                }
                .buttonStyle(BorderedActionButtonStyle(color: AppTheme.amber))
            }
            if model.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                FeedbackText(text: "模型名称不能为空", color: AppTheme.red)
            }
        }
        .padding(12)
        .background(AppTheme.controlBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: model) { value in store.updateModelMonitors(store.modelMonitors) }
    }
}

private struct MonitorEditor: View {
    @Binding var monitor: CustomMonitor
    @ObservedObject var store: StatusStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("启用监测", isOn: $monitor.enabled).font(.body).tint(AppTheme.green).frame(minHeight: 48)
            LabeledField(title: "显示名称", placeholder: "我的服务", text: $monitor.label)
            LabeledField(title: "HTTPS 地址", placeholder: "https://example.com", text: $monitor.url)
            SettingPicker(title: "延迟阈值", selection: $monitor.thresholdMS, options: [1000, 1500, 3000], suffix: " ms")
            if !monitor.url.isEmpty && !StatusEngine.validateMonitorURL(monitor.url) {
                FeedbackText(text: "只支持有效的 HTTPS 地址", color: AppTheme.red)
            }
        }
        .padding(12)
        .background(AppTheme.controlBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: monitor) { value in store.updateMonitors(store.monitors) }
    }
}

private struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundColor(AppTheme.secondary)
            TextField(placeholder, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(AppTheme.card)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.divider, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

private struct BackendMetric: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.body).foregroundColor(AppTheme.secondary)
            Spacer(minLength: 12)
            Text(value).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundColor(AppTheme.primary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 42)
        .accessibilityElement(children: .combine)
    }
}

private struct LogCategoryToggle: View {
    let category: AppLogCategory
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon).frame(width: 24).foregroundColor(isOn ? AppTheme.green : AppTheme.secondary)
                Text(category.label).font(.body).foregroundColor(AppTheme.primary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundColor(isOn ? AppTheme.green : AppTheme.secondary)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("日志类型\(category.label)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct FeedbackText: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle.fill").foregroundColor(color)
            Text(text).font(.subheadline).foregroundColor(color).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
