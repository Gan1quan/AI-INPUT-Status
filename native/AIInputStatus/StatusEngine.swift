import Foundation

// MARK: - Errors

enum StatusEngineError: LocalizedError {
    case invalidResponse
    case http(Int)
    case invalidPayload
    case noDaemonPayload
    case network(String)
    case subscription(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "未收到有效响应"
        case .http(let code): return "HTTP \(code)"
        case .invalidPayload: return "状态数据格式异常"
        case .noDaemonPayload: return "后台服务尚未生成状态数据"
        case .network(let message), .subscription(let message): return message
        }
    }
}

// MARK: - Engine

enum StatusEngine {
    static let cacheKey = "ai-input-status-native-cache-v5"
    static let monitorsKey = "ai-input-custom-monitors-native-v1"
    static let monitorResultsKey = "ai-input-custom-monitor-results-native-v1"
    static let notificationKey = "ai-input-notification-settings-native-v1"
    static let eventsKey = "ai-input-status-events-native-v1"
    static let alertKey = "ai-input-status-alert-native-v1"
    static let cacheVersion = 5
    static let freshInterval: TimeInterval = 180
    static let staleInterval: TimeInterval = 600
    static let cacheExpiry: TimeInterval = 1800

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

    static func decodeDaemonEnvelope(_ data: Data) throws -> DaemonEnvelope {
        try decoder.decode(DaemonEnvelope.self, from: data)
    }

    static func decodePayload(_ data: Data) throws -> (Date, [ServiceStatus]) {
        let raw = try decoder.decode(RawPayload.self, from: data)
        guard let rawServices = raw.services else { throw StatusEngineError.invalidPayload }
        let generated = Date(timeIntervalSince1970: raw.generatedAt ?? Date().timeIntervalSince1970)
        let services = targetModels.map { model -> ServiceStatus in
            guard let item = rawServices.first(where: { $0.model == model }) else {
                let missing = Probe(timestamp: generated, ok: nil, latencyMS: nil, error: "状态接口未返回该模型")
                return ServiceStatus(model: model, uptimePercent: nil, last: missing, history: [])
            }
            let last = item.last.map { rawProbe in
                Probe(timestamp: validDate(rawProbe.timestamp, fallback: generated), ok: rawProbe.ok,
                      latencyMS: integerLatency(rawProbe.latencyMS), error: safeError(rawProbe.error))
            }
            let history = (item.history ?? []).compactMap { rawProbe -> Probe? in
                guard let timestamp = rawProbe.timestamp, timestamp.isFinite, timestamp > 0,
                      let ok = rawProbe.ok else { return nil }
                return Probe(timestamp: Date(timeIntervalSince1970: timestamp), ok: ok,
                             latencyMS: integerLatency(rawProbe.latencyMS), error: safeError(rawProbe.error))
            }.suffix(240)
            return ServiceStatus(model: model, uptimePercent: boundedPercent(item.uptimePercent), last: last, history: Array(history))
        }
        return (generated, services)
    }

    private static func validDate(_ timestamp: Double?, fallback: Date) -> Date {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return fallback }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func integerLatency(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return Int(value.rounded())
    }

    private static func boundedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    private static func safeError(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : String(normalized.prefix(240))
    }

    // MARK: Cache and settings

    static func loadCachedStatus() -> StatusSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let envelope = try? decoder.decode(CachedEnvelope.self, from: data),
              envelope.version <= cacheVersion else { return nil }
        let value = envelope.snapshot
        return StatusSnapshot(generatedAt: value.generatedAt, services: value.services,
                             fetchedAt: value.fetchedAt, source: .cache, gateway: value.gateway,
                             customMonitors: value.customMonitors, gatewayFromCache: true,
                             lastError: value.lastError)
    }

    static func saveCachedStatus(_ snapshot: StatusSnapshot) {
        guard let data = try? encoder.encode(CachedEnvelope(version: cacheVersion, snapshot: snapshot)) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    static func loadNotificationSettings() -> NotificationSettings {
        guard let data = UserDefaults.standard.data(forKey: notificationKey),
              let value = try? decoder.decode(NotificationSettings.self, from: data) else { return NotificationSettings() }
        return value
    }

    static func saveNotificationSettings(_ value: NotificationSettings) {
        guard let data = try? encoder.encode(value) else { return }
        UserDefaults.standard.set(data, forKey: notificationKey)
    }

    static func loadMonitors() -> [CustomMonitor] {
        guard let data = UserDefaults.standard.data(forKey: monitorsKey),
              let value = try? decoder.decode([CustomMonitor].self, from: data) else { return [] }
        return Array(value.prefix(20))
    }

    static func saveMonitors(_ value: [CustomMonitor]) {
        guard let data = try? encoder.encode(Array(value.prefix(20))) else { return }
        UserDefaults.standard.set(data, forKey: monitorsKey)
    }

    static func loadCustomMonitorResults() -> [CustomMonitorResult] {
        guard let data = UserDefaults.standard.data(forKey: monitorResultsKey),
              let value = try? decoder.decode([CustomMonitorResult].self, from: data) else { return [] }
        return value
    }

    static func saveCustomMonitorResults(_ value: [CustomMonitorResult]) {
        guard let data = try? encoder.encode(value) else { return }
        UserDefaults.standard.set(data, forKey: monitorResultsKey)
    }

    static func validateMonitorURL(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    // MARK: Diagnostics and events

    static func diagnostics(_ snapshot: StatusSnapshot, settings: NotificationSettings, now: Date = Date()) -> [DiagnosticItem] {
        var result: [DiagnosticItem] = []
        if snapshot.age > cacheExpiry {
            result.append(DiagnosticItem(id: "cache-expired", severity: .failure, title: "缓存已过期", detail: "超过 30 分钟未取得有效状态", date: snapshot.fetchedAt))
        } else if snapshot.source == .cache {
            result.append(DiagnosticItem(id: "local-cache", severity: .warning, title: "正在使用本地缓存", detail: "网络恢复后会自动刷新", date: snapshot.fetchedAt))
        }
        if let gateway = snapshot.gateway, gateway.classification != .ok {
            result.append(DiagnosticItem(id: "gateway", severity: .warning, title: "本机网关探测异常", detail: gateway.detail, date: gateway.measuredAt))
        }
        for service in snapshot.services {
            if let error = service.last?.error {
                let severity: DiagnosticItem.Severity = service.last?.ok == false ? .failure : .warning
                result.append(DiagnosticItem(id: "service-\(service.model)", severity: severity, title: "官方状态 · \(service.model)", detail: error, date: service.last?.timestamp))
            }
            let failures = consecutiveFailureMinutes(service, now: now)
            if failures >= settings.failureMinutes {
                result.append(DiagnosticItem(id: "failure-\(service.model)", severity: .failure, title: "\(service.model) 连续失败", detail: "最近 \(failures) 个完整分钟未恢复", date: now))
            }
        }
        for monitor in snapshot.customMonitors where monitor.classification != "ok" {
            result.append(DiagnosticItem(id: "custom-\(monitor.id)", severity: .failure, title: "\(monitor.label) 监测异常", detail: monitor.detail, date: monitor.checkedAt))
        }
        return result
    }

    static func loadEvents() -> [StatusEvent] {
        guard let data = UserDefaults.standard.data(forKey: eventsKey),
              let value = try? decoder.decode([StatusEvent].self, from: data) else { return [] }
        return Array(value.suffix(120).reversed())
    }

    static func updateEvents(_ snapshot: StatusSnapshot, settings: NotificationSettings, now: Date = Date()) -> StatusChanges {
        let previous = loadAlertKeys()
        var current: [String] = []
        for service in snapshot.services where consecutiveFailureMinutes(service, now: now) >= settings.failureMinutes {
            current.append("official|\(service.model)")
        }
        if let gateway = snapshot.gateway, settings.gatewayEnabled,
           (gateway.classification != .ok || (gateway.latencyMS ?? 0) >= settings.gatewayThresholdMS) {
            current.append("gateway|ai.input.im")
        }
        for monitor in snapshot.customMonitors where monitor.classification != "ok" {
            current.append("custom|\(monitor.id)")
        }
        let opened = current.filter { !previous.contains($0) }.map { makeEvent(key: $0, phase: .opened, now: now) }
        let recovered = previous.filter { !current.contains($0) }.map { makeEvent(key: $0, phase: .recovered, now: now) }
        appendEvents(opened + recovered)
        saveAlertKeys(current)
        return StatusChanges(opened: opened, recovered: recovered)
    }

    private static func makeEvent(key: String, phase: StatusEvent.Phase, now: Date) -> StatusEvent {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        let source: StatusEvent.Source = parts.first == "gateway" ? .gateway : parts.first == "custom" ? .custom : .official
        let target = parts.count > 1 ? parts[1] : key
        return StatusEvent(id: "\(phase.rawValue)-\(key)-\(now.timeIntervalSince1970)", phase: phase, source: source, target: target,
                           classification: phase == .opened ? "failure" : "recovered",
                           detail: phase == .opened ? "检测异常" : "已恢复", date: now)
    }

    private static func appendEvents(_ newEvents: [StatusEvent]) {
        guard !newEvents.isEmpty else { return }
        let all = Array((loadEvents().reversed() + newEvents).suffix(120))
        guard let data = try? encoder.encode(all) else { return }
        UserDefaults.standard.set(data, forKey: eventsKey)
    }

    private static func loadAlertKeys() -> [String] {
        guard let raw = UserDefaults.standard.string(forKey: alertKey),
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return value
    }

    private static func saveAlertKeys(_ value: [String]) {
        guard let data = try? JSONEncoder().encode(value), let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: alertKey)
    }

    // MARK: History and statistics

    static func serviceState(_ service: ServiceStatus, now: Date = Date()) -> ServiceState {
        guard let last = service.last, let ok = last.ok else { return .unknown }
        let age = now.timeIntervalSince(last.timestamp)
        if age < -120 || age > staleInterval { return .unknown }
        if age > freshInterval { return .stale }
        return ok ? .online : .offline
    }

    static func historySummary(_ service: ServiceStatus, range: HistoryRange, now: Date = Date()) -> HistorySummary {
        let currentMinute = Int(floor(now.timeIntervalSince1970 / 60))
        let firstMinute = currentMinute - range.rawValue
        var values: [Int: Bool] = [:]
        for point in service.history {
            guard let ok = point.ok else { continue }
            let minute = Int(floor(point.timestamp.timeIntervalSince1970 / 60))
            guard minute >= firstMinute && minute < currentMinute else { continue }
            if values[minute] == false || !ok { values[minute] = false } else { values[minute] = true }
        }
        let slots = (0..<range.rawValue).map { values[firstMinute + $0] }
        let succeeded = slots.compactMap { $0 }.filter { $0 }.count
        let failed = slots.compactMap { $0 }.filter { !$0 }.count
        let observed = succeeded + failed
        return HistorySummary(slots: slots, observed: observed, missing: range.rawValue - observed, succeeded: succeeded, failed: failed,
                              successRate: observed == 0 ? nil : Double(succeeded) / Double(observed) * 100)
    }

    static func latencyStats(_ service: ServiceStatus, range: HistoryRange, now: Date = Date()) -> LatencyStats {
        let currentMinute = Int(floor(now.timeIntervalSince1970 / 60))
        let firstMinute = currentMinute - range.rawValue
        let values = service.history.compactMap { point -> Int? in
            let minute = Int(floor(point.timestamp.timeIntervalSince1970 / 60))
            guard minute >= firstMinute && minute < currentMinute else { return nil }
            return point.latencyMS
        }.sorted()
        guard !values.isEmpty else { return LatencyStats(count: 0, minimum: nil, median: nil, maximum: nil) }
        let middle = values.count / 2
        let median = values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        return LatencyStats(count: values.count, minimum: values.first, median: median, maximum: values.last)
    }

    static func consecutiveFailureMinutes(_ service: ServiceStatus, now: Date = Date(), range: HistoryRange = .sixty) -> Int {
        var count = 0
        for value in historySummary(service, range: range, now: now).slots.reversed() {
            guard value == false else { break }
            count += 1
        }
        return count
    }

    static func dailyStatistics(_ service: ServiceStatus, now: Date = Date()) -> DailyStatistics {
        let start = Calendar.current.startOfDay(for: now)
        let points = service.history.filter { $0.timestamp >= start && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
        guard let first = points.first else { return DailyStatistics(normal: 0, abnormal: 0, incidents: 0) }
        var normal: TimeInterval = 0
        var abnormal: TimeInterval = 0
        var incidents = first.ok == true ? 0 : 1
        for index in points.indices {
            let end = index + 1 < points.count ? points[index + 1].timestamp : now
            let duration = max(0, end.timeIntervalSince(points[index].timestamp))
            if points[index].ok == true { normal += duration } else { abnormal += duration }
            if index + 1 < points.count, points[index].ok == true, points[index + 1].ok == false { incidents += 1 }
        }
        return DailyStatistics(normal: normal, abnormal: abnormal, incidents: incidents)
    }

    static func dataTrustLabel(_ snapshot: StatusSnapshot) -> String {
        if snapshot.age > cacheExpiry { return "expired" }
        switch snapshot.source {
        case .daemon: return "live"
        case .publicAPI: return "live · api"
        case .cache: return "cache · \(ageLabel(snapshot.age))"
        }
    }

    static func ageLabel(_ age: TimeInterval) -> String {
        let seconds = max(0, Int(age))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
