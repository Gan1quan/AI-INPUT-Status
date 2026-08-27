import Foundation

// MARK: - Endpoints

let statusEndpoint = URL(string: "https://status.input.im/api/status")!
let gatewayEndpoint = URL(string: "https://ai.input.im")!
let daemonStatusEndpoint = URL(string: "http://127.0.0.1:17891/status")!
let daemonRefreshEndpoint = URL(string: "http://127.0.0.1:17891/refresh")!
let subscriptionEndpoint = URL(string: "https://ai.input.im/api/v1/subscriptions?timezone=Asia%2FShanghai")!
let targetModels = ["gpt-5.6-sol", "gpt-5.6-terra"]

// MARK: - Raw public API models

struct RawPayload: Decodable {
    let generatedAt: Double?
    let services: [RawService]?
    enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", services }
}

struct RawService: Decodable {
    let model: String?
    let uptimePercent: Double?
    let last: RawProbe?
    let history: [RawProbe]?
    enum CodingKeys: String, CodingKey { case model, uptimePercent = "uptime_pct", last, history }
}

struct RawProbe: Decodable {
    let timestamp: Double?
    let ok: Bool?
    let latencyMS: Double?
    let error: String?
    enum CodingKeys: String, CodingKey { case timestamp = "ts", ok, latencyMS = "latency_ms", error }
}

// MARK: - Status models

enum ServiceState: String { case online, offline, stale, unknown }
enum DataSource: String, Codable { case daemon, publicAPI, cache }
enum GatewayClassification: String, Codable { case ok, redirect, clientError, serverError, networkError, timeout, unavailable }

struct Probe: Codable, Hashable, Identifiable {
    let timestamp: Date
    let ok: Bool?
    let latencyMS: Int?
    let error: String?
    var id: String { "\(timestamp.timeIntervalSince1970)-\(ok == true)" }
    enum CodingKeys: String, CodingKey { case timestamp = "ts", ok, latencyMS = "latency_ms", error }
}

struct ServiceStatus: Codable, Hashable, Identifiable {
    var id: String { model }
    let model: String
    let uptimePercent: Double?
    let last: Probe?
    let history: [Probe]
    enum CodingKeys: String, CodingKey { case model, uptimePercent = "uptime_pct", last, history }
}

struct GatewayStatus: Codable, Hashable {
    let latencyMS: Int?
    let measuredAt: Date?
    let responseStatus: Int?
    let classification: GatewayClassification
    let detail: String
}

struct CustomMonitor: Codable, Hashable, Identifiable {
    var id: String
    var enabled: Bool
    var label: String
    var url: String
    var thresholdMS: Int
}

struct CustomMonitorResult: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let checkedAt: Date
    let latencyMS: Int?
    let statusCode: Int?
    let classification: String
    let detail: String
    let consecutiveFailures: Int
    let lastSuccessAt: Date?
}

struct StatusSnapshot: Codable, Hashable {
    let generatedAt: Date
    let services: [ServiceStatus]
    let fetchedAt: Date
    let source: DataSource
    let gateway: GatewayStatus?
    let customMonitors: [CustomMonitorResult]
    let gatewayFromCache: Bool
    let lastError: String?
    var age: TimeInterval { max(0, Date().timeIntervalSince(fetchedAt)) }
}

struct PluginStatus: Codable, Hashable {
    let version: Int
    let daemon: String
    let attempts: Int
    let successes: Int
    let failures: Int
    let lastAttempt: TimeInterval
    let lastSuccess: TimeInterval
    let lastFailure: TimeInterval
    let lastInterval: TimeInterval
    let lastError: String?
    let payload: String?
    enum CodingKeys: String, CodingKey {
        case version, daemon, attempts, successes, failures, payload
        case lastAttempt = "last_attempt", lastSuccess = "last_success", lastFailure = "last_failure"
        case lastInterval = "last_interval", lastError = "last_error"
    }
    var lastSuccessDate: Date? { lastSuccess > 0 ? Date(timeIntervalSince1970: lastSuccess) : nil }
}

struct DaemonEnvelope: Decodable {
    let version: Int?
    let daemon: String?
    let attempts: Int?
    let successes: Int?
    let failures: Int?
    let lastAttempt: Double?
    let lastSuccess: Double?
    let lastFailure: Double?
    let lastInterval: Double?
    let lastError: String?
    let payload: String?
    enum CodingKeys: String, CodingKey {
        case version, daemon, attempts, successes, failures, payload
        case lastAttempt = "last_attempt", lastSuccess = "last_success", lastFailure = "last_failure"
        case lastInterval = "last_interval", lastError = "last_error"
    }
    var pluginStatus: PluginStatus {
        PluginStatus(version: version ?? 0, daemon: daemon ?? "unknown", attempts: attempts ?? 0,
                     successes: successes ?? 0, failures: failures ?? 0, lastAttempt: lastAttempt ?? 0,
                     lastSuccess: lastSuccess ?? 0, lastFailure: lastFailure ?? 0,
                     lastInterval: lastInterval ?? 0, lastError: lastError, payload: payload)
    }
}

// MARK: - History and diagnostics

struct DailyStatistics {
    let normal: TimeInterval
    let abnormal: TimeInterval
    let incidents: Int
    var availability: Double {
        let total = normal + abnormal
        return total > 0 ? normal / total * 100 : 0
    }
}

enum HistoryRange: Int, CaseIterable, Hashable {
    case sixty = 60
    case oneEighty = 180
    case twoForty = 240
    var label: String { "\(rawValue)m" }
}

struct HistorySummary {
    let slots: [Bool?]
    let observed: Int
    let missing: Int
    let succeeded: Int
    let failed: Int
    let successRate: Double?
}

struct LatencyStats {
    let count: Int
    let minimum: Int?
    let median: Int?
    let maximum: Int?
}

struct DiagnosticItem: Identifiable, Hashable {
    enum Severity: String { case info, warning, failure }
    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let date: Date?
}

struct StatusEvent: Identifiable, Codable, Hashable {
    enum Phase: String, Codable { case opened, recovered }
    enum Source: String, Codable { case official, gateway, custom }
    let id: String
    let phase: Phase
    let source: Source
    let target: String
    let classification: String
    let detail: String
    let date: Date
}

struct StatusChanges {
    let opened: [StatusEvent]
    let recovered: [StatusEvent]
}

// MARK: - Subscription

struct SubscriptionPlan: Codable, Hashable, Identifiable {
    let name: String
    let platform: String
    let rateMultiplier: Double
    let dailyLimitUSD: Double
    let dailyUsageUSD: Double
    let weeklyUsageUSD: Double
    let monthlyUsageUSD: Double
    let expiresAt: Date
    let status: String
    var id: String { "\(platform)-\(name)-\(expiresAt.timeIntervalSince1970)" }
    var usagePercent: Double {
        guard dailyLimitUSD > 0 else { return 0 }
        return min(100, max(0, dailyUsageUSD / dailyLimitUSD * 100))
    }
    var remainingUSD: Double { max(0, dailyLimitUSD - dailyUsageUSD) }
    func isActive(at date: Date = Date()) -> Bool { status == "active" && expiresAt > date && dailyLimitUSD > 0 }
}

struct SubscriptionSnapshot: Codable, Hashable {
    let plans: [SubscriptionPlan]
    let fetchedAt: Date
    let fromCache: Bool
    let error: String?
    init(plans: [SubscriptionPlan], fetchedAt: Date, fromCache: Bool, error: String? = nil) {
        self.plans = plans
        self.fetchedAt = fetchedAt
        self.fromCache = fromCache
        self.error = error
    }
    var age: TimeInterval { max(0, Date().timeIntervalSince(fetchedAt)) }
}

struct SubscriptionSummary {
    let activePlans: Int
    let totalLimitUSD: Double
    let totalUsageUSD: Double
    let totalRemainingUSD: Double
    let expiringSoonCount: Int
}

enum SubscriptionHealth { case ready, cached, stale, unconfigured, unauthorized, networkError, serverError, invalidResponse, unknown }

// MARK: - Settings and persistence

struct NotificationSettings: Codable, Hashable {
    var enabled = true
    var recoveryEnabled = true
    var gatewayEnabled = false
    var subscriptionQuotaEnabled = true
    var subscriptionExpiryEnabled = true
    var failureMinutes = 2
    var gatewayThresholdMS = 1500
    var subscriptionQuotaThreshold = 85
}

struct CachedEnvelope: Codable {
    let version: Int
    let snapshot: StatusSnapshot
}
