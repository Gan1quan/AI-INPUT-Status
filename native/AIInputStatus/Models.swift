import Foundation

// MARK: - Endpoints

let statusEndpoint = URL(string: "https://status.input.im/api/status")!
let gatewayEndpoint = URL(string: "https://ai.input.im")!
let daemonStatusEndpoint = URL(string: "http://127.0.0.1:17891/status")!
let daemonRefreshEndpoint = URL(string: "http://127.0.0.1:17891/refresh")!
let subscriptionEndpoint = URL(string: "https://ai.input.im/api/v1/subscriptions?timezone=Asia%2FShanghai")!
let defaultTargetModels = ["gpt-5.6-sol", "gpt-5.6-terra"]
let sharedDefaults = UserDefaults(suiteName: "group.com.gan1quan.aiinputstatus") ?? .standard

// MARK: - Raw status payload

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

// MARK: - Status

enum DataSource: String, Codable { case daemon, publicAPI, cache }
enum GatewayClassification: String, Codable { case ok, redirect, clientError, serverError, networkError, timeout, unavailable }

enum ServiceState: String {
    case online, offline, misconfigured, unauthorized, quotaExhausted, rateLimited
    case timeout, networkError, serverError, clientError, stale, unknown
}

enum ServiceIssue: Int, Equatable {
    case generic = 0, configuration, authentication, quota, rateLimit, timeout, network, server, client

    static func from(_ message: String?) -> ServiceIssue {
        ServiceIssue(rawValue: RustCore.errorKind(message)) ?? .generic
    }

    var state: ServiceState {
        switch self {
        case .generic: return .offline
        case .configuration: return .misconfigured
        case .authentication: return .unauthorized
        case .quota: return .quotaExhausted
        case .rateLimit: return .rateLimited
        case .timeout: return .timeout
        case .network: return .networkError
        case .server: return .serverError
        case .client: return .clientError
        }
    }

    var title: String {
        switch self {
        case .generic: return "服务不可用"
        case .configuration: return "模型未配置"
        case .authentication: return "认证失败"
        case .quota: return "额度耗尽"
        case .rateLimit: return "请求限流"
        case .timeout: return "请求超时"
        case .network: return "网络异常"
        case .server: return "服务端异常"
        case .client: return "请求配置异常"
        }
    }

    var recommendation: String {
        switch self {
        case .generic: return "请重新检测，并查看技术详情"
        case .configuration: return "该模型不在当前账号组中，请修改模型配置或启用可用模型"
        case .authentication: return "请检查账号授权或重新导入 Token"
        case .quota: return "请等待额度重置或切换有剩余额度的账号"
        case .rateLimit: return "请稍后重试，或降低并发请求"
        case .timeout: return "请重新检测；持续发生时检查网络或上游服务"
        case .network: return "请检查当前网络连接后重新检测"
        case .server: return "上游服务异常，请稍后重试"
        case .client: return "请检查模型名称、账号组和请求参数"
        }
    }
}

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

// MARK: - User model configuration

struct ModelMonitor: Codable, Hashable, Identifiable {
    var id: String
    var model: String
    var provider: String
    var account: String
    var enabled: Bool
    var mutedUntil: Date?
    var maintenanceUntil: Date?

    init(id: String, model: String, provider: String = "", account: String = "", enabled: Bool = true, mutedUntil: Date? = nil, maintenanceUntil: Date? = nil) {
        self.id = id; self.model = model; self.provider = provider; self.account = account; self.enabled = enabled; self.mutedUntil = mutedUntil; self.maintenanceUntil = maintenanceUntil
    }

    enum CodingKeys: String, CodingKey { case id, model, provider, account, enabled, mutedUntil, maintenanceUntil }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? model
        provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? ""
        account = try values.decodeIfPresent(String.self, forKey: .account) ?? ""
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mutedUntil = try values.decodeIfPresent(Date.self, forKey: .mutedUntil)
        maintenanceUntil = try values.decodeIfPresent(Date.self, forKey: .maintenanceUntil)
    }

    var isMuted: Bool { (mutedUntil ?? .distantPast) > Date() }
    var isInMaintenance: Bool { (maintenanceUntil ?? .distantPast) > Date() }

    static func defaults() -> [ModelMonitor] {
        defaultTargetModels.map { ModelMonitor(id: $0, model: $0, provider: "Input", account: "默认账号") }
    }
}

// MARK: - History and diagnostics

enum HistoryRange: Int, CaseIterable, Hashable {
    case sixty = 60, oneEighty = 180, twoForty = 240
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
    let p95: Int?
    let maximum: Int?
}

struct DiagnosticItem: Identifiable, Hashable {
    enum Severity: String { case info, warning, failure }
    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let technicalDetail: String?
    let date: Date?
    let repair: DiagnosticRepair
}

enum DiagnosticRepair: String, Hashable { case refresh, configureModels, configureToken, none }

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

struct StatusChanges { let opened: [StatusEvent]; let recovered: [StatusEvent] }

struct DailyStatistics {
    let normal: TimeInterval
    let abnormal: TimeInterval
    let incidents: Int
    var availability: Double {
        let total = normal + abnormal
        return total > 0 ? normal / total * 100 : 0
    }
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
    var usagePercent: Double { guard dailyLimitUSD > 0 else { return 0 }; return min(100, max(0, dailyUsageUSD / dailyLimitUSD * 100)) }
    var remainingUSD: Double { max(0, dailyLimitUSD - dailyUsageUSD) }
    func isActive(at date: Date = Date()) -> Bool { status == "active" && expiresAt > date && dailyLimitUSD > 0 }
}

struct SubscriptionSnapshot: Codable, Hashable {
    let plans: [SubscriptionPlan]
    let fetchedAt: Date
    let fromCache: Bool
    let error: String?
    init(plans: [SubscriptionPlan], fetchedAt: Date, fromCache: Bool, error: String? = nil) {
        self.plans = plans; self.fetchedAt = fetchedAt; self.fromCache = fromCache; self.error = error
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

struct NotificationSettings: Codable, Hashable {
    var enabled = true
    var recoveryEnabled = true
    var gatewayEnabled = false
    var subscriptionQuotaEnabled = true
    var subscriptionExpiryEnabled = true
    var failureMinutes = 2
    var gatewayThresholdMS = 1500
    var subscriptionQuotaThreshold = 85

    enum CodingKeys: String, CodingKey { case enabled, recoveryEnabled, gatewayEnabled, subscriptionQuotaEnabled, subscriptionExpiryEnabled, failureMinutes, gatewayThresholdMS, subscriptionQuotaThreshold }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        recoveryEnabled = try c.decodeIfPresent(Bool.self, forKey: .recoveryEnabled) ?? true
        gatewayEnabled = try c.decodeIfPresent(Bool.self, forKey: .gatewayEnabled) ?? false
        subscriptionQuotaEnabled = try c.decodeIfPresent(Bool.self, forKey: .subscriptionQuotaEnabled) ?? true
        subscriptionExpiryEnabled = try c.decodeIfPresent(Bool.self, forKey: .subscriptionExpiryEnabled) ?? true
        failureMinutes = max(1, try c.decodeIfPresent(Int.self, forKey: .failureMinutes) ?? 2)
        gatewayThresholdMS = max(100, try c.decodeIfPresent(Int.self, forKey: .gatewayThresholdMS) ?? 1500)
        subscriptionQuotaThreshold = min(100, max(1, try c.decodeIfPresent(Int.self, forKey: .subscriptionQuotaThreshold) ?? 85))
    }
}

struct CachedEnvelope: Codable { let version: Int; let snapshot: StatusSnapshot }

// MARK: - UI support

enum DiagnosticFilter: String, CaseIterable, Identifiable {
    case all, healthy, configuration, authentication, quota, rateLimit, timeout, network, server, client
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .healthy: return "正常"
        case .configuration: return "配置"
        case .authentication: return "认证"
        case .quota: return "额度"
        case .rateLimit: return "限流"
        case .timeout: return "超时"
        case .network: return "网络"
        case .server: return "服务端"
        case .client: return "请求"
        }
    }
}

enum ServiceGrouping: String, CaseIterable, Identifiable {
    case model, provider, account
    var id: String { rawValue }
    var label: String { switch self { case .model: return "按模型"; case .provider: return "按供应商"; case .account: return "按账号" } }
}

enum ExportFormat { case csv, json }

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}
