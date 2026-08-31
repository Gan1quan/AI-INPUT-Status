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
        case .network(let text), .subscription(let text): return text
        }
    }
}

enum StatusEngine {
    static let cacheKey = "ai-input-status-native-cache-v5"
    static let monitorsKey = "ai-input-custom-monitors-native-v1"
    static let modelMonitorsKey = "ai-input-model-monitors-native-v1"
    static let monitorResultsKey = "ai-input-custom-monitor-results-native-v1"
    static let notificationKey = "ai-input-notification-settings-native-v1"
    static let eventsKey = "ai-input-status-events-native-v1"
    static let alertKey = "ai-input-status-alert-native-v1"
    static let cacheVersion = 6
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
        let generated = validDate(raw.generatedAt, fallback: Date())
        let names = enabledModelNames()
        let services = names.map { model -> ServiceStatus in
            guard let item = rawServices.first(where: { $0.model?.trimmingCharacters(in: .whitespacesAndNewlines) == model }) else {
                // This is a configuration/compatibility problem, not a network
                // outage. Keeping it explicit prevents the UI from showing 0/0.
                return ServiceStatus(model: model, uptimePercent: nil,
                                     last: Probe(timestamp: generated, ok: nil, latencyMS: nil,
                                                 error: "状态接口未返回该模型"), history: [])
            }
            let last = item.last.map {
                Probe(timestamp: validDate($0.timestamp, fallback: generated),
                      ok: $0.ok,
                      latencyMS: integerLatency($0.latencyMS),
                      error: safeError($0.error))
            }
            let history = (item.history ?? []).compactMap { probe -> Probe? in
                guard let timestamp = probe.timestamp, timestamp.isFinite, timestamp > 0 else { return nil }
                return Probe(timestamp: Date(timeIntervalSince1970: timestamp),
                             ok: probe.ok,
                             latencyMS: integerLatency(probe.latencyMS),
                             error: safeError(probe.error))
            }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(480)
            return ServiceStatus(model: model,
                                 uptimePercent: boundedPercent(item.uptimePercent),
                                 last: last,
                                 history: Array(history))
        }
        return (generated, services)
    }

    private static func validDate(_ value: Double?, fallback: Date) -> Date {
        guard let value, value.isFinite, value > 0 else { return fallback }
        return Date(timeIntervalSince1970: value)
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
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(500))
    }

    static func loadCachedStatus() -> StatusSnapshot? {
        guard let data = sharedDefaults.data(forKey: cacheKey),
              let envelope = try? decoder.decode(CachedEnvelope.self, from: data),
              envelope.version <= cacheVersion else { return nil }
        let value = envelope.snapshot
        return StatusSnapshot(generatedAt: value.generatedAt,
                              services: value.services,
                              fetchedAt: value.fetchedAt,
                              source: .cache,
                              gateway: value.gateway,
                              customMonitors: value.customMonitors,
                              gatewayFromCache: true,
                              lastError: value.lastError)
    }

    static func saveCachedStatus(_ snapshot: StatusSnapshot) {
        guard let data = try? encoder.encode(CachedEnvelope(version: cacheVersion, snapshot: snapshot)) else { return }
        sharedDefaults.set(data, forKey: cacheKey)
    }

    static func loadNotificationSettings() -> NotificationSettings {
        guard let data = sharedDefaults.data(forKey: notificationKey),
              let value = try? decoder.decode(NotificationSettings.self, from: data) else { return NotificationSettings() }
        return value
    }

    static func saveNotificationSettings(_ value: NotificationSettings) {
        guard let data = try? encoder.encode(value) else { return }
        sharedDefaults.set(data, forKey: notificationKey)
    }

    static func loadMonitors() -> [CustomMonitor] {
        guard let data = sharedDefaults.data(forKey: monitorsKey),
              let value = try? decoder.decode([CustomMonitor].self, from: data) else { return [] }
        return Array(value.prefix(20))
    }

    static func saveMonitors(_ value: [CustomMonitor]) {
        guard let data = try? encoder.encode(Array(value.prefix(20))) else { return }
        sharedDefaults.set(data, forKey: monitorsKey)
    }

    static func loadCustomMonitorResults() -> [CustomMonitorResult] {
        guard let data = sharedDefaults.data(forKey: monitorResultsKey),
              let value = try? decoder.decode([CustomMonitorResult].self, from: data) else { return [] }
        return value
    }

    static func saveCustomMonitorResults(_ value: [CustomMonitorResult]) {
        guard let data = try? encoder.encode(value) else { return }
        sharedDefaults.set(data, forKey: monitorResultsKey)
    }

    static func loadModelMonitors() -> [ModelMonitor] {
        guard let data = sharedDefaults.data(forKey: modelMonitorsKey),
              let value = try? decoder.decode([ModelMonitor].self, from: data),
              !value.isEmpty else { return ModelMonitor.defaults() }
        return value
    }

    static func saveModelMonitors(_ value: [ModelMonitor]) {
        guard let data = try? encoder.encode(value) else { return }
        sharedDefaults.set(data, forKey: modelMonitorsKey)
    }

    static func enabledModelNames() -> [String] {
        var seen = Set<String>()
        return loadModelMonitors().compactMap { monitor in
            let name = monitor.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard monitor.enabled, !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    static func validateMonitorURL(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    // MARK: Diagnostics and events

    static func diagnostics(_ snapshot: StatusSnapshot, settings: NotificationSettings, now: Date = Date()) -> [DiagnosticItem] {
        var result: [DiagnosticItem] = []
        if snapshot.age > cacheExpiry {
            result.append(DiagnosticItem(id: "cache-expired", severity: .failure,
                                         title: "状态缓存已过期",
                                         detail: "超过 30 分钟没有取得有效状态。请重新检测。",
                                         technicalDetail: nil, date: snapshot.fetchedAt, repair: .refresh))
        } else if snapshot.source == .cache {
            result.append(DiagnosticItem(id: "local-cache", severity: .warning,
                                         title: "正在使用本地缓存",
                                         detail: "网络恢复后会自动刷新。最后成功更新：\(clock(snapshot.fetchedAt))",
                                         technicalDetail: nil, date: snapshot.fetchedAt, repair: .refresh))
        }

        if let gateway = snapshot.gateway, gateway.classification != .ok {
            result.append(DiagnosticItem(id: "gateway", severity: .warning,
                                         title: "状态 API 探测异常",
                                         detail: "\(gateway.detail)。模型数据可能不是实时结果。",
                                         technicalDetail: gateway.detail, date: gateway.measuredAt, repair: .refresh))
        }

        for service in snapshot.services {
            let state = serviceState(service, now: now)
            if state == .waiting {
                result.append(DiagnosticItem(id: "waiting-\(service.model)", severity: .info,
                                             title: "等待首次检测 · \(service.model)",
                                             detail: "尚未收到该模型的有效采样。点击重新检测获取结果。",
                                             technicalDetail: service.last?.error,
                                             date: service.last?.timestamp, repair: .refresh))
            } else if state == .notConfigured {
                result.append(DiagnosticItem(id: "config-\(service.model)", severity: .failure,
                                             title: "模型未被接口返回 · \(service.model)",
                                             detail: "这通常表示当前账号组不支持该模型，不是网络离线。请检查模型配置。",
                                             technicalDetail: service.last?.error,
                                             date: service.last?.timestamp, repair: .configureModels))
            } else if state == .stale {
                result.append(DiagnosticItem(id: "stale-\(service.model)", severity: .warning,
                                             title: "模型数据已过期 · \(service.model)",
                                             detail: "最后一次采样距今已超过 3 分钟。请重新检测。",
                                             technicalDetail: service.last?.error,
                                             date: service.last?.timestamp, repair: .refresh))
            } else if let error = service.last?.error, state != .online {
                let issue = ServiceIssue.from(error)
                result.append(DiagnosticItem(id: "service-\(service.model)",
                                             severity: service.last?.ok == false ? .failure : .warning,
                                             title: "\(issue.title) · \(service.model)",
                                             detail: "\(issue.recommendation)。",
                                             technicalDetail: error,
                                             date: service.last?.timestamp,
                                             repair: issue == .configuration ? .configureModels : issue == .authentication ? .configureToken : .refresh))
            }

            let failures = consecutiveFailureMinutes(service, now: now)
            if failures >= settings.failureMinutes && service.last?.error == nil {
                result.append(DiagnosticItem(id: "failure-\(service.model)", severity: .failure,
                                             title: "\(service.model) 连续失败",
                                             detail: "最近 \(failures) 个完整分钟未恢复。",
                                             technicalDetail: nil, date: now, repair: .refresh))
            }
        }

        for monitor in snapshot.customMonitors where monitor.classification != "ok" {
            result.append(DiagnosticItem(id: "custom-\(monitor.id)", severity: .failure,
                                         title: "\(monitor.label) 监测异常",
                                         detail: "\(monitor.detail)。请检查地址或网络。",
                                         technicalDetail: monitor.detail, date: monitor.checkedAt, repair: .refresh))
        }
        return result
    }

    static func loadEvents() -> [StatusEvent] {
        guard let data = sharedDefaults.data(forKey: eventsKey),
              let value = try? decoder.decode([StatusEvent].self, from: data) else { return [] }
        return Array(value.sorted { $0.date > $1.date }.prefix(120))
    }

    static func updateEvents(_ snapshot: StatusSnapshot, settings: NotificationSettings, now: Date = Date()) -> StatusChanges {
        let previous = loadAlertKeys()
        var current: [String] = []
        var configurations: [String: ModelMonitor] = [:]
        for value in loadModelMonitors() { configurations[value.model] = value }
        for service in snapshot.services {
            let config = configurations[service.model]
            if !(config?.isMuted ?? false) && !(config?.isInMaintenance ?? false),
               consecutiveFailureMinutes(service, now: now) >= settings.failureMinutes {
                current.append("official|\(service.model)")
            }
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
        return StatusEvent(id: "\(phase.rawValue)-\(key)-\(now.timeIntervalSince1970)",
                           phase: phase, source: source, target: target,
                           classification: phase == .opened ? "failure" : "recovered",
                           detail: phase == .opened ? "检测异常" : "已恢复", date: now)
    }

    private static func appendEvents(_ values: [StatusEvent]) {
        guard !values.isEmpty else { return }
        let chronological = Array(loadEvents().reversed()) + values
        let all = Array(chronological.suffix(120))
        guard let data = try? encoder.encode(all) else { return }
        sharedDefaults.set(data, forKey: eventsKey)
    }

    private static func loadAlertKeys() -> [String] {
        guard let raw = sharedDefaults.string(forKey: alertKey),
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return value
    }

    private static func saveAlertKeys(_ value: [String]) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8) else { return }
        sharedDefaults.set(raw, forKey: alertKey)
    }

    // MARK: Time-window calculations

    static func serviceIssue(_ service: ServiceStatus) -> ServiceIssue? {
        guard service.last?.ok == false || service.last?.error != nil else { return nil }
        return ServiceIssue.from(service.last?.error)
    }

    static func serviceState(_ service: ServiceStatus, now: Date = Date()) -> ServiceState {
        guard let last = service.last else { return .waiting }
        if let ok = last.ok {
            let age = now.timeIntervalSince(last.timestamp)
            if age < -120 { return .unknown }
            if age > staleInterval { return .stale }
            if age > freshInterval { return .stale }
            return ok ? .online : ServiceIssue.from(last.error).state
        }
        if let error = last.error, ServiceIssue.from(error) == .configuration {
            return .notConfigured
        }
        return .waiting
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
        let rate = RustCore.successRate(slots)
        return HistorySummary(slots: slots, observed: observed, missing: range.rawValue - observed,
                              succeeded: succeeded, failed: failed, successRate: rate)
    }

    /// Returns one latency sample per real minute in the selected time window.
    /// This avoids treating the last N probes as N minutes when sampling is sparse.
    static func latencyValues(_ service: ServiceStatus, range: HistoryRange, now: Date = Date()) -> [Int] {
        let currentMinute = Int(floor(now.timeIntervalSince1970 / 60))
        let firstMinute = currentMinute - range.rawValue
        var values: [Int: (Date, Int)] = [:]
        for point in service.history {
            guard let latency = point.latencyMS, latency >= 0 else { continue }
            let minute = Int(floor(point.timestamp.timeIntervalSince1970 / 60))
            guard minute >= firstMinute && minute < currentMinute else { continue }
            if values[minute] == nil || point.timestamp > values[minute]!.0 {
                values[minute] = (point.timestamp, latency)
            }
        }
        return values.keys.sorted().compactMap { values[$0]?.1 }
    }

    static func latencyStats(_ service: ServiceStatus, range: HistoryRange, now: Date = Date()) -> LatencyStats {
        let values = latencyValues(service, range: range, now: now).sorted()
        guard !values.isEmpty else { return LatencyStats(count: 0, minimum: nil, median: nil, p95: nil, maximum: nil) }
        let middle = values.count / 2
        let median = values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        return LatencyStats(count: values.count, minimum: values.first, median: median,
                            p95: RustCore.p95(values), maximum: values.last)
    }

    static func consecutiveFailureMinutes(_ service: ServiceStatus, now: Date = Date(), range: HistoryRange = .sixty) -> Int {
        var count = 0
        for value in historySummary(service, range: range, now: now).slots.reversed() {
            guard value == false else { break }
            count += 1
        }
        return count
    }

    static func matches(_ filter: DiagnosticFilter, service: ServiceStatus, now: Date = Date()) -> Bool {
        let state = serviceState(service, now: now)
        let issue = ServiceIssue.from(service.last?.error)
        switch filter {
        case .all: return true
        case .healthy: return state == .online
        case .issues: return state != .online && state != .waiting
        case .waiting: return state == .waiting
        case .stale: return state == .stale
        case .configuration: return state == .notConfigured || state == .misconfigured || issue == .configuration
        case .authentication: return state == .unauthorized || issue == .authentication
        case .quota: return state == .quotaExhausted || issue == .quota
        case .rateLimit: return state == .rateLimited || issue == .rateLimit
        case .timeout: return state == .timeout || issue == .timeout
        case .network: return state == .networkError || issue == .network
        case .server: return state == .serverError || issue == .server
        case .client: return state == .clientError || issue == .client
        }
    }

    static func dataTrustLabel(_ snapshot: StatusSnapshot) -> String {
        if snapshot.age > cacheExpiry { return "缓存已过期" }
        switch snapshot.source {
        case .daemon: return "实时 · DEB"
        case .publicAPI: return "实时 · API"
        case .cache: return "缓存 · \(ageLabel(snapshot.age))"
        }
    }

    static func ageLabel(_ age: TimeInterval) -> String {
        let seconds = max(0, Int(age))
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }
}
