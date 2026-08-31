import Foundation
import SwiftUI
import WidgetKit

private struct WidgetProbe: Decodable { let ok: Bool? }
private struct WidgetService: Decodable { let last: WidgetProbe? }
private struct WidgetStatus: Decodable { let services: [WidgetService] }
private struct WidgetEnvelope: Decodable { let snapshot: WidgetStatus }
private struct WidgetPlan: Decodable { let dailyLimitUSD: Double; let dailyUsageUSD: Double; let expiresAt: Date; let status: String; var active: Bool { status == "active" && expiresAt > Date() } }
private struct WidgetSubCache: Decodable { let plans: [WidgetPlan] }
struct AIInputStatusWidgetEntry: TimelineEntry { let date: Date; let available: Int; let total: Int; let remaining: String; let freshness: String }
struct AIInputStatusWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AIInputStatusWidgetEntry { AIInputStatusWidgetEntry(date: Date(), available: 0, total: 0, remaining: "--", freshness: "等待数据") }
    func getSnapshot(in context: Context, completion: @escaping (AIInputStatusWidgetEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AIInputStatusWidgetEntry>) -> Void) { completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(900)))) }
    private func load() -> AIInputStatusWidgetEntry {
        let defaults = UserDefaults(suiteName: "group.com.gan1quan.aiinputstatus"); let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var available = 0; var total = 0; var freshness = "等待数据"
        if let data = defaults?.data(forKey: "ai-input-status-native-cache-v5"), let box = try? decoder.decode(WidgetEnvelope.self, from: data) { total = box.snapshot.services.count; available = box.snapshot.services.filter { $0.last?.ok == true }.count; freshness = "状态已同步" }
        var remaining = "--"
        if let data = defaults?.data(forKey: "ai-input-subscription-native-cache-v3"), let box = try? decoder.decode(WidgetSubCache.self, from: data) { let plans = box.plans.filter(\.active); let limit = plans.reduce(0) { $0 + $1.dailyLimitUSD }; let usage = plans.reduce(0) { $0 + min($1.dailyUsageUSD, $1.dailyLimitUSD) }; remaining = plans.isEmpty ? "--" : String(format: "$%.2f", max(0, limit - usage)) }
        return AIInputStatusWidgetEntry(date: Date(), available: available, total: total, remaining: remaining, freshness: freshness)
    }
}
struct AIInputStatusWidgetView: View { let entry: AIInputStatusWidgetEntry; var body: some View { VStack(alignment: .leading, spacing: 5) { HStack { Text("AI INPUT").font(.system(.headline, design: .monospaced)); Spacer(); Image(systemName: entry.available == entry.total && entry.total > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill") }; Text("模型 \(entry.available)/\(entry.total) 可用").font(.system(.body, design: .monospaced)); Text("剩余 \(entry.remaining)").font(.system(.body, design: .monospaced)).bold(); Text(entry.freshness).font(.caption2).foregroundStyle(.secondary) }.background(Color.black) } }
@main struct AIInputStatusWidget: Widget { let kind = "AIInputStatusWidget"; var body: some WidgetConfiguration { StaticConfiguration(kind: kind, provider: AIInputStatusWidgetProvider()) { entry in AIInputStatusWidgetView(entry: entry) }.configurationDisplayName("AI INPUT 状态").description("显示模型可用性和订阅剩余额度").supportedFamilies([.systemSmall, .systemMedium]) } }
