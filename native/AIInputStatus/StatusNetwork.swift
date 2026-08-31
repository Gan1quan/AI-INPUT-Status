import Foundation

struct StatusLoadResult { let snapshot: StatusSnapshot; let plugin: PluginStatus? }
private struct GatewayMeasurement { let statusCode: Int; let latencyMS: Int?; let timedOut: Bool }
private struct NetworkError: LocalizedError { let message: String; var errorDescription: String? { message } }

enum StatusNetwork {
    private static let gatewayTimeout: TimeInterval = 6
    private static let customTimeout: TimeInterval = 6

    static func loadStatus() async throws -> StatusLoadResult {
        async let gatewayTask = measureGateway()
        let payload: Data
        let source: DataSource
        var plugin: PluginStatus?
        do {
            let result = try await loadDaemonPayload()
            payload = result.payload
            plugin = result.plugin
            source = .daemon
        } catch {
            payload = try await request(statusEndpoint, timeout: 12)
            if let daemon = try? await loadDaemonStatus() { plugin = daemon.0 }
            source = .publicAPI
        }
        let decoded = try StatusEngine.decodePayload(payload)
        let gateway = await gatewayTask
        let monitors = await probeCustomMonitors(StatusEngine.loadMonitors())
        let snapshot = StatusSnapshot(generatedAt: decoded.0, services: decoded.1, fetchedAt: Date(), source: source, gateway: gateway, customMonitors: monitors, gatewayFromCache: false, lastError: nil)
        StatusEngine.saveCustomMonitorResults(monitors)
        StatusEngine.saveCachedStatus(snapshot)
        return StatusLoadResult(snapshot: snapshot, plugin: plugin)
    }

    static func loadDaemonStatus() async throws -> (PluginStatus, Data?) {
        let data = try await request(daemonStatusEndpoint, timeout: 3)
        let envelope = try StatusEngine.decodeDaemonEnvelope(data)
        return (envelope.pluginStatus, envelope.payload?.data(using: .utf8))
    }

    private static func loadDaemonPayload() async throws -> (payload: Data, plugin: PluginStatus) {
        let data = try await request(daemonRefreshEndpoint, timeout: 14)
        let envelope = try StatusEngine.decodeDaemonEnvelope(data)
        guard let body = envelope.payload?.data(using: .utf8) else { throw StatusEngineError.noDaemonPayload }
        return (body, envelope.pluginStatus)
    }

    private static func request(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetworkError(message: "无有效 HTTP 响应") }
            guard (200..<300).contains(http.statusCode) else { throw NetworkError(message: "HTTP \(http.statusCode)") }
            return data
        } catch let error as NetworkError { throw error }
        catch let error as URLError { throw NetworkError(message: error.code == .timedOut ? "请求超时" : error.code == .cancelled ? "请求已取消" : "网络不可用") }
        catch { throw NetworkError(message: "网络请求失败") }
    }

    static func measureGateway() async -> GatewayStatus {
        let measurements = await withTaskGroup(of: GatewayMeasurement.self, returning: [GatewayMeasurement].self) { group in
            for _ in 0..<3 { group.addTask { await measureGatewayOnce() } }
            var values: [GatewayMeasurement] = []
            for await value in group { values.append(value) }
            return values
        }
        let successful = measurements.compactMap { value -> Int? in
            guard (200..<300).contains(value.statusCode), let latency = value.latencyMS else { return nil }
            return latency
        }.sorted()
        if !successful.isEmpty {
            let median = successful[successful.count / 2]
            return GatewayStatus(latencyMS: median, measuredAt: Date(), responseStatus: 200, classification: .ok, detail: "正常 · \(median) ms")
        }
        if let status = measurements.first(where: { $0.statusCode > 0 })?.statusCode {
            let cls: GatewayClassification = (300..<400).contains(status) ? .redirect : (400..<500).contains(status) ? .clientError : status >= 500 ? .serverError : .unavailable
            return GatewayStatus(latencyMS: nil, measuredAt: Date(), responseStatus: status, classification: cls, detail: "HTTP \(status)")
        }
        let timeout = measurements.contains { $0.timedOut }
        return GatewayStatus(latencyMS: nil, measuredAt: Date(), responseStatus: nil, classification: timeout ? .timeout : .networkError, detail: timeout ? "请求超时" : "网络不可用")
    }

    private static func measureGatewayOnce() async -> GatewayMeasurement {
        let started = Date()
        var request = URLRequest(url: gatewayEndpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = gatewayTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return GatewayMeasurement(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, latencyMS: max(1, Int(Date().timeIntervalSince(started) * 1000)), timedOut: false)
        } catch let error as URLError { return GatewayMeasurement(statusCode: 0, latencyMS: nil, timedOut: error.code == .timedOut) }
        catch { return GatewayMeasurement(statusCode: 0, latencyMS: nil, timedOut: false) }
    }

    static func probeCustomMonitors(_ monitors: [CustomMonitor]) async -> [CustomMonitorResult] {
        await withTaskGroup(of: CustomMonitorResult?.self, returning: [CustomMonitorResult].self) { group in
            for monitor in monitors.filter(\.enabled) { group.addTask { await probe(monitor) } }
            var values: [CustomMonitorResult] = []
            for await value in group { if let value { values.append(value) } }
            return values.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        }
    }

    private static func probe(_ monitor: CustomMonitor) async -> CustomMonitorResult? {
        let previous = StatusEngine.loadCustomMonitorResults().first { $0.id == monitor.id }
        guard StatusEngine.validateMonitorURL(monitor.url), let url = URL(string: monitor.url) else {
            return CustomMonitorResult(id: monitor.id, label: monitor.label, checkedAt: Date(), latencyMS: nil, statusCode: nil, classification: "invalid-url", detail: "请输入 HTTPS 地址", consecutiveFailures: previous?.consecutiveFailures ?? 0, lastSuccessAt: previous?.lastSuccessAt)
        }
        let started = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = customTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let latency = max(1, Int(Date().timeIntervalSince(started) * 1000))
            let classification = (300..<400).contains(status) ? "redirect" : (400..<500).contains(status) ? "client-error" : status >= 500 ? "server-error" : latency >= monitor.thresholdMS ? "slow" : "ok"
            let ok = classification == "ok"
            return CustomMonitorResult(id: monitor.id, label: monitor.label, checkedAt: Date(), latencyMS: latency, statusCode: status, classification: classification, detail: ok ? "正常 · \(latency) ms" : classification == "slow" ? "延迟过高 · \(latency) ms" : "HTTP \(status)", consecutiveFailures: ok ? 0 : (previous?.consecutiveFailures ?? 0) + 1, lastSuccessAt: ok ? Date() : previous?.lastSuccessAt)
        } catch let error as URLError {
            let timeout = error.code == .timedOut
            return CustomMonitorResult(id: monitor.id, label: monitor.label, checkedAt: Date(), latencyMS: nil, statusCode: nil, classification: timeout ? "timeout" : "network-error", detail: timeout ? "请求超时" : "网络不可用", consecutiveFailures: (previous?.consecutiveFailures ?? 0) + 1, lastSuccessAt: previous?.lastSuccessAt)
        } catch {
            return CustomMonitorResult(id: monitor.id, label: monitor.label, checkedAt: Date(), latencyMS: nil, statusCode: nil, classification: "network-error", detail: "探测失败", consecutiveFailures: (previous?.consecutiveFailures ?? 0) + 1, lastSuccessAt: previous?.lastSuccessAt)
        }
    }
}
