import Foundation
import SwiftUI
import WidgetKit

struct AIInputStatusWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetDataSnapshot
}

struct AIInputStatusWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AIInputStatusWidgetEntry {
        let services = [
            WidgetServiceData(model: "模型 A", state: "waiting", stateLabel: "待检测", latencyMS: nil,
                              uptimePercent: nil, windowSuccessRate: nil, observed: 0, window: 60, error: nil),
            WidgetServiceData(model: "模型 B", state: "waiting", stateLabel: "待检测", latencyMS: nil,
                              uptimePercent: nil, windowSuccessRate: nil, observed: 0, window: 60, error: nil)
        ]
        let snapshot = WidgetDataSnapshot(version: WidgetDataSnapshot.currentVersion,
                                          configuredCount: 2,
                                          source: "placeholder",
                                          sourceLabel: "等待首次检测",
                                          dataState: "waiting",
                                          dataStateLabel: "等待数据",
                                          updatedAt: Date(), generatedAt: nil,
                                          services: services, quota: nil, backend: nil,
                                          message: "打开 App 完成首次同步")
        return AIInputStatusWidgetEntry(date: Date(), snapshot: snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (AIInputStatusWidgetEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AIInputStatusWidgetEntry>) -> Void) {
        let entry = load()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func load() -> AIInputStatusWidgetEntry {
        let snapshot = WidgetDataStore.load() ?? WidgetDataSnapshot.waiting(message: "打开 App 完成首次同步")
        return AIInputStatusWidgetEntry(date: snapshot.updatedAt, snapshot: snapshot)
    }
}

struct AIInputStatusWidgetView: View {
    let entry: AIInputStatusWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var selectedServices: [WidgetServiceData] {
        let selection = WidgetDataStore.selection
        let values = entry.snapshot.services(for: selection)
        // If a selected model was deleted, keep the Widget useful instead of
        // rendering an empty card until the user changes the setting.
        return values.isEmpty && selection != WidgetModelSelection.all.rawValue
            ? entry.snapshot.services
            : values
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: smallBody
            case .systemLarge: largeBody
            default: mediumBody
            }
        }
        .padding(14)
        .background(Color.black)
        .foregroundColor(.white)
        .widgetURL(URL(string: "aiinputstatus://status"))
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            titleRow
            Spacer(minLength: 2)
            if entry.snapshot.configuredCount == 0 {
                Text("未配置模型").font(.system(.headline, design: .rounded)).bold()
                Text("请打开 App 设置").font(.system(.caption, design: .rounded)).foregroundColor(.gray)
            } else if selectedServices.isEmpty {
                Text("\(entry.snapshot.configuredCount) 个模型").font(.system(.headline, design: .rounded)).bold()
                Text(entry.snapshot.dataStateLabel).font(.system(.caption, design: .rounded)).foregroundColor(.gray)
            } else {
                Text("\(healthyCount)/\(selectedServices.count) 正常")
                    .font(.system(.headline, design: .rounded)).bold()
                    .minimumScaleFactor(0.75)
                if let quota = entry.snapshot.quota {
                    Text(quotaText(quota)).font(.system(.caption, design: .rounded)).foregroundColor(quotaColor(quota))
                }
            }
            Spacer(minLength: 0)
            Text(updateText).font(.system(.caption2, design: .rounded)).foregroundColor(.gray)
        }
    }

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            if entry.snapshot.configuredCount == 0 {
                emptyMessage
            } else if selectedServices.isEmpty {
                emptyMessage
            } else {
                ForEach(Array(selectedServices.prefix(3))) { service in
                    serviceRow(service, compact: true)
                }
                footerRow
            }
        }
    }

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            HStack(alignment: .firstTextBaseline) {
                Text(statusHeadline).font(.system(.title3, design: .rounded)).bold()
                Spacer()
                Text("\(healthyCount)/\(max(selectedServices.count, entry.snapshot.configuredCount))")
                    .font(.system(.title2, design: .monospaced)).bold()
                    .foregroundColor(statusColor)
            }
            Divider().overlay(Color.gray.opacity(0.35))
            if selectedServices.isEmpty {
                emptyMessage
            } else {
                ForEach(Array(selectedServices.prefix(8))) { service in
                    serviceRow(service, compact: false)
                }
            }
            Spacer(minLength: 2)
            HStack {
                if let quota = entry.snapshot.quota {
                    Text(quotaText(quota)).foregroundColor(quotaColor(quota))
                } else {
                    Text("额度：未配置或等待数据").foregroundColor(.gray)
                }
                Spacer()
                Text(entry.snapshot.sourceLabel).foregroundColor(.gray)
            }
            .font(.system(.caption, design: .rounded))
            Text("更新于 \(entry.snapshot.updatedAt.formatted(date: .omitted, time: .shortened)) · 点击打开 App")
                .font(.system(.caption2, design: .rounded)).foregroundColor(.gray)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon).foregroundColor(statusColor)
            Text("AI INPUT").font(.system(.headline, design: .monospaced)).bold()
            Spacer()
            if entry.snapshot.dataState == "live" { Text("LIVE").foregroundColor(.green) }
        }
        .font(.system(.caption, design: .rounded))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI INPUT，\(statusHeadline)，\(entry.snapshot.sourceLabel)")
    }

    private var emptyMessage: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.snapshot.configuredCount == 0 ? "未配置模型" : entry.snapshot.dataStateLabel)
                .font(.system(.headline, design: .rounded)).bold()
            Text(entry.snapshot.message ?? "打开 App 后点击立即刷新")
                .font(.system(.caption, design: .rounded)).foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func serviceRow(_ service: WidgetServiceData, compact: Bool) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color(for: service)).frame(width: 8, height: 8)
            Text(service.model)
                .font(.system(compact ? .subheadline : .body, design: .monospaced)).bold()
                .lineLimit(1).minimumScaleFactor(0.65)
            Spacer(minLength: 4)
            Text(service.stateLabel).foregroundColor(color(for: service))
                .font(.system(.subheadline, design: .rounded)).bold()
            if let latency = service.latencyMS {
                Text("\(latency) ms").foregroundColor(.gray)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(service.model)，\(service.stateLabel)，\(service.latencyMS.map { "\($0) 毫秒" } ?? "暂无延迟")")
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if let quota = entry.snapshot.quota { Text(quotaText(quota)).foregroundColor(quotaColor(quota)) }
            Text("· \(entry.snapshot.sourceLabel)").foregroundColor(.gray)
            Spacer()
            Text(updateText).foregroundColor(.gray)
        }
        .font(.system(.caption2, design: .rounded))
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private var healthyCount: Int { selectedServices.filter { $0.state == "online" }.count }
    private var statusHeadline: String {
        if entry.snapshot.configuredCount == 0 { return "未配置模型" }
        if selectedServices.isEmpty { return entry.snapshot.dataStateLabel }
        return healthyCount == selectedServices.count ? "所有模型正常" : "存在异常"
    }
    private var statusColor: Color {
        if entry.snapshot.configuredCount == 0 || selectedServices.isEmpty { return .orange }
        return healthyCount == selectedServices.count ? .green : .orange
    }
    private var statusIcon: String {
        if entry.snapshot.configuredCount == 0 || selectedServices.isEmpty { return "exclamationmark.triangle.fill" }
        return healthyCount == selectedServices.count ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }
    private var updateText: String {
        entry.snapshot.dataState == "waiting" ? "等待同步" : entry.snapshot.updatedAt.formatted(date: .omitted, time: .shortened)
    }

    private func color(for service: WidgetServiceData) -> Color {
        switch service.state {
        case "online": return .green
        case "waiting": return .gray
        case "stale", "notConfigured": return .orange
        default: return .red
        }
    }

    private func quotaText(_ quota: WidgetQuotaData) -> String {
        guard let remaining = quota.remainingUSD else { return quota.stateLabel }
        return "额度剩余 $\(String(format: "%.2f", remaining))"
    }

    private func quotaColor(_ quota: WidgetQuotaData) -> Color {
        quota.state == "ready" ? .green : quota.state == "stale" ? .orange : .gray
    }
}

@main
struct AIInputStatusWidget: Widget {
    let kind = "AIInputStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AIInputStatusWidgetProvider()) { entry in
            AIInputStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("AI INPUT 状态")
        .description("显示模型状态、延迟、额度和数据更新时间")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
