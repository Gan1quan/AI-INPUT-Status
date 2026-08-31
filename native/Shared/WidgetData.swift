import Foundation

/// App Group bridge shared by the application and the Widget extension.
/// Keep this file free of SwiftUI/WidgetKit so both targets use the same schema.
struct WidgetServiceData: Codable, Hashable, Identifiable {
    let model: String
    let state: String
    let stateLabel: String
    let latencyMS: Int?
    let uptimePercent: Double?
    let windowSuccessRate: Double?
    let observed: Int
    let window: Int
    let error: String?

    var id: String { model }
}

struct WidgetQuotaData: Codable, Hashable {
    let state: String
    let stateLabel: String
    let remainingUSD: Double?
    let limitUSD: Double?
    let usageUSD: Double?
    let planCount: Int
    let fetchedAt: Date?
}

struct WidgetBackendData: Codable, Hashable {
    let state: String
    let stateLabel: String
    let attempts: Int
    let successes: Int
    let failures: Int
    let lastSuccess: Date?
}

struct WidgetDataSnapshot: Codable, Hashable {
    static let currentVersion = 2

    let version: Int
    let configuredCount: Int
    let source: String
    let sourceLabel: String
    let dataState: String
    let dataStateLabel: String
    let updatedAt: Date
    let generatedAt: Date?
    let services: [WidgetServiceData]
    let quota: WidgetQuotaData?
    let backend: WidgetBackendData?
    let message: String?

    static func waiting(configuredCount: Int = 0, message: String? = nil) -> WidgetDataSnapshot {
        WidgetDataSnapshot(version: currentVersion,
                           configuredCount: configuredCount,
                           source: "waiting",
                           sourceLabel: "等待首次检测",
                           dataState: "waiting",
                           dataStateLabel: "等待数据",
                           updatedAt: Date(),
                           generatedAt: nil,
                           services: [],
                           quota: nil,
                           backend: nil,
                           message: message)
    }

    func services(for selection: String) -> [WidgetServiceData] {
        guard selection != WidgetModelSelection.all.rawValue else { return services }
        return services.filter { $0.model == selection }
    }
}

enum WidgetModelSelection: String, CaseIterable, Identifiable, Hashable {
    case all = "*"
    var id: String { rawValue }
    var label: String { "全部模型" }
}

enum WidgetDataStore {
    static let suiteName = "group.com.gan1quan.aiinputstatus"
    static let dataKey = "ai-input-widget-data-v2"
    static let selectionKey = "ai-input-widget-selection-v1"

    private static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }
    private static var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }
    private static var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    static func load() -> WidgetDataSnapshot? {
        guard let data = defaults.data(forKey: dataKey),
              let value = try? decoder.decode(WidgetDataSnapshot.self, from: data),
              value.version <= WidgetDataSnapshot.currentVersion else { return nil }
        return value
    }

    static func save(_ value: WidgetDataSnapshot) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: dataKey)
        // The bridge is small; synchronize helps a freshly installed Widget see
        // the first snapshot immediately on systems where the app is suspended.
        defaults.synchronize()
    }

    static var selection: String {
        let value = defaults.string(forKey: selectionKey) ?? WidgetModelSelection.all.rawValue
        return value.isEmpty ? WidgetModelSelection.all.rawValue : value
    }

    static func setSelection(_ value: String) {
        defaults.set(value.isEmpty ? WidgetModelSelection.all.rawValue : value, forKey: selectionKey)
        defaults.synchronize()
    }
}
