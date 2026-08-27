import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: StatusStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                subscriptionSection
                notificationSection
                monitorSection
                backendSection
                eventsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }.foregroundColor(AppTheme.green)
                }
            }
        }
    }

    private var subscriptionSection: some View {
        Section {
            HStack {
                Image(systemName: "creditcard.fill").foregroundColor(AppTheme.green)
                Text(store.tokenConfigured ? "Token 已配置" : "未配置订阅 Token")
                Spacer()
                Text(store.subscription.map { SubscriptionEngine.healthLabel(SubscriptionEngine.health($0, tokenConfigured: store.tokenConfigured, error: store.subscriptionError)) } ?? "--")
                    .foregroundColor(AppTheme.secondary)
                    .font(.footnote)
            }
            SecureField("粘贴 Bearer Token", text: $store.tokenDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            HStack {
                Button { store.pasteToken() } label: { Label("从剪贴板粘贴", systemImage: "doc.on.clipboard") }
                Spacer()
                Button { Task { await store.saveToken() } } label: { Label("保存并读取", systemImage: "arrow.down.circle") }
                    .disabled(store.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.subscriptionRefreshing)
            }
            if store.tokenConfigured {
                HStack {
                    Button { Task { await store.refreshSubscription() } } label: { Label("刷新额度", systemImage: "arrow.clockwise") }
                        .disabled(store.subscriptionRefreshing)
                    Spacer()
                    Button(role: .destructive) { store.removeToken() } label: { Label("删除 Token", systemImage: "key.slash") }
                }
            }
            if let error = store.subscriptionError {
                Text(error).font(.footnote).foregroundColor(AppTheme.amber)
            }
            Text("Token 仅保存于本机 Keychain；Safari 用户脚本仍可分享至 Scripting，原生 IPA 使用剪贴板导入。")
                .font(.footnote)
                .foregroundColor(AppTheme.secondary)
        } header: {
            Text("订阅额度")
        }
    }

    private var notificationSection: some View {
        Section {
            Toggle("状态异常提醒", isOn: boolBinding(\.enabled))
            Toggle("恢复提醒", isOn: boolBinding(\.recoveryEnabled))
            Toggle("网关延迟提醒", isOn: boolBinding(\.gatewayEnabled))
            Toggle("每日额度提醒", isOn: boolBinding(\.subscriptionQuotaEnabled))
            Toggle("订阅到期提醒", isOn: boolBinding(\.subscriptionExpiryEnabled))
            Picker("连续失败阈值", selection: intBinding(\.failureMinutes)) {
                Text("2 分钟").tag(2)
                Text("5 分钟").tag(5)
                Text("10 分钟").tag(10)
            }
            Picker("网关延迟阈值", selection: intBinding(\.gatewayThresholdMS)) {
                Text("1000 ms").tag(1000)
                Text("1500 ms").tag(1500)
                Text("3000 ms").tag(3000)
            }
            Picker("额度提醒阈值", selection: intBinding(\.subscriptionQuotaThreshold)) {
                Text("70%").tag(70)
                Text("85%").tag(85)
                Text("95%").tag(95)
            }
            Button { Task { await store.requestNotificationPermission() } } label: {
                Label("请求系统通知权限", systemImage: "bell.badge")
            }
        } header: {
            Text("通知")
        } footer: {
            Text("通知由 IPA 在刷新状态或读取订阅额度时判断；DEB 不保存 Token，也不发送订阅通知。")
        }
    }

    private var monitorSection: some View {
        Section {
            if store.monitors.isEmpty {
                Text("暂无自定义监测目标").foregroundColor(AppTheme.secondary)
            }
            ForEach($store.monitors) { $monitor in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $monitor.enabled) {
                        Text(monitor.label.isEmpty ? "新监测目标" : monitor.label)
                    }
                    TextField("显示名称", text: $monitor.label)
                    TextField("https://example.com", text: $monitor.url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Picker("延迟阈值", selection: $monitor.thresholdMS) {
                        Text("1000 ms").tag(1000)
                        Text("1500 ms").tag(1500)
                        Text("3000 ms").tag(3000)
                    }
                    if !monitor.url.isEmpty && !StatusEngine.validateMonitorURL(monitor.url) {
                        Text("只支持有效的 HTTPS 地址").font(.footnote).foregroundColor(AppTheme.red)
                    }
                }
                .onChange(of: monitor) { _ in store.updateMonitors(store.monitors) }
            }
            .onDelete(perform: store.deleteMonitor)
            Button { store.addMonitor() } label: {
                Label("添加 HTTPS 监测", systemImage: "plus.circle")
            }
            .disabled(store.monitors.count >= 20)
        } header: {
            Text("自定义监测 · \(store.monitors.count)/20")
        } footer: {
            Text("使用当前设备网络发送 HEAD 请求；自定义监测不会进入 DEB 后台。")
        }
    }

    private var backendSection: some View {
        Section {
            HStack {
                Text("后台服务")
                Spacer()
                Text(store.pluginHealthLabel).foregroundColor(pluginColor)
            }
            if let plugin = store.pluginStatus {
                LabeledContent("累计请求", value: "\(plugin.attempts) 次")
                LabeledContent("成功 / 失败", value: "\(plugin.successes) / \(plugin.failures)")
                LabeledContent("最近成功", value: clock(plugin.lastSuccessDate))
                LabeledContent("最近间隔", value: plugin.lastInterval > 0 ? String(format: "%.1f 秒", plugin.lastInterval) : "--")
                LabeledContent("状态来源", value: store.sourceLabel)
                if let error = plugin.lastError { Text(error).font(.footnote).foregroundColor(AppTheme.amber) }
            } else {
                Text("未连接 RootHide DEB 1.1.1；公共状态会回退到 API。")
                    .font(.footnote).foregroundColor(AppTheme.secondary)
            }
        } header: {
            Text("后台链路")
        } footer: {
            Text("SpringBoard → Darwin 通知 → aiinputstatusd；当前版本不修改 DEB。")
        }
    }

    private var eventsSection: some View {
        Section {
            let events = StatusEngine.loadEvents().prefix(12)
            if events.isEmpty {
                Text("暂无异常事件").foregroundColor(AppTheme.secondary)
            } else {
                ForEach(Array(events)) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: event.phase == .opened ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .foregroundColor(event.phase == .opened ? AppTheme.red : AppTheme.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.target) · \(event.phase == .opened ? "异常" : "恢复")")
                            Text("\(event.detail) · \(clock(event.date))")
                                .font(.footnote).foregroundColor(AppTheme.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("最近异常事件")
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("应用版本", value: "3.4.2 native")
            LabeledContent("系统要求", value: "iOS 16.1+")
            LabeledContent("Widget", value: "未包含（按生产要求）")
            Link("打开 AI INPUT", destination: gatewayEndpoint)
        }
    }

    private var pluginColor: Color {
        switch store.pluginHealth {
        case .healthy: return AppTheme.green
        case .stale, .starting: return AppTheme.amber
        case .failed: return AppTheme.red
        case .unavailable: return AppTheme.secondary
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
