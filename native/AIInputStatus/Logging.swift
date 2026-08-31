import Foundation

enum AppLogCategory: String, CaseIterable, Hashable, Identifiable, Codable {
    case status
    case backend
    case subscription
    case action

    var id: String { rawValue }
    var label: String {
        switch self {
        case .status: return "状态检测"
        case .backend: return "后台链路"
        case .subscription: return "额度订阅"
        case .action: return "用户操作"
        }
    }
    var icon: String {
        switch self {
        case .status: return "waveform.path.ecg"
        case .backend: return "server.rack"
        case .subscription: return "creditcard"
        case .action: return "hand.tap"
        }
    }
}

enum AppLogRange: String, CaseIterable, Identifiable {
    case day
    case week
    case all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "最近 24 小时"
        case .week: return "最近 7 天"
        case .all: return "全部日志"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .all: return nil
        }
    }
}

enum AppLogFormat: String, CaseIterable, Identifiable {
    case text
    case json
    case csv

    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: return "文本 TXT"
        case .json: return "结构化 JSON"
        case .csv: return "表格 CSV"
        }
    }
    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .json: return "json"
        case .csv: return "csv"
        }
    }
}

struct AppLogEntry: Codable, Hashable, Identifiable {
    let id: String
    let date: Date
    let category: AppLogCategory
    let event: String
    let detail: String
}

enum AppLogStore {
    private static let key = "ai-input-app-logs-v1"
    private static let maximum = 800
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

    static func load() -> [AppLogEntry] {
        guard let data = sharedDefaults.data(forKey: key),
              let entries = try? decoder.decode([AppLogEntry].self, from: data) else { return [] }
        return entries.sorted { $0.date > $1.date }
    }

    static func append(category: AppLogCategory, event: String, detail: String) {
        let entry = AppLogEntry(id: UUID().uuidString, date: Date(), category: category, event: event, detail: detail)
        let entries = Array(([entry] + load()).prefix(maximum))
        guard let data = try? encoder.encode(entries) else { return }
        sharedDefaults.set(data, forKey: key)
    }

    static func clear() {
        sharedDefaults.removeObject(forKey: key)
    }
}

struct LogExportRow: Codable, Hashable, Identifiable {
    let id: String
    let date: Date
    let category: String
    let event: String
    let detail: String
}
