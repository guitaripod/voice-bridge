import Foundation
import VoiceKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum NIMProbeResult: Sendable, Equatable {
    case ready
    case loading(String)
    case down(String)

    /// `"triton_status":"ready"` is ready, 503 is still loading, anything else that answered is not
    /// ready yet, and no answer is down.
    public static func interpret(status: Int, body: Data) -> NIMProbeResult {
        if (200..<300).contains(status) {
            let triton = JSONValue.parse(String(decoding: body, as: UTF8.self))?["triton_status"]?.string
            if triton == "ready" { return .ready }
            return .loading("The voice engine reports \(triton ?? "no status").")
        }
        if status == 503 { return .loading("The voice engine is loading, this can take five minutes.") }
        return .down("The voice engine health check answered \(status).")
    }
}

public protocol NIMHealthProbe: Sendable {
    func check() async -> NIMProbeResult
}

/// `GET /v1/realtime/health` on the same host and port as the realtime socket.
public struct HTTPNIMHealthProbe: NIMHealthProbe {
    public let url: URL?
    public let timeout: Double

    public init(nimURL: String, timeout: Double = 1.5) {
        url = Self.healthURL(for: nimURL)
        self.timeout = timeout
    }

    public static func healthURL(for nimURL: String) -> URL? {
        guard var parts = URLComponents(string: nimURL) else { return nil }
        switch parts.scheme {
        case "ws": parts.scheme = "http"
        case "wss": parts.scheme = "https"
        default: break
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        parts.path = path + "/health"
        return parts.url
    }

    public func check() async -> NIMProbeResult {
        guard let url else { return .down("VOICE_NIM_URL is not a URL.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .down("The voice engine answered oddly.") }
            return NIMProbeResult.interpret(status: http.statusCode, body: data)
        } catch {
            return .down("The voice engine is not reachable.")
        }
    }
}

/// Keeps one answer for a couple of seconds so a screen polling `/health` does not hammer the NIM.
actor NIMHealthMonitor {
    private let probe: any NIMHealthProbe
    private let clock: any VoiceClock
    private let ttl: Double
    private var cached: (result: NIMProbeResult, at: Double)?
    private var inflight: Task<NIMProbeResult, Never>?

    init(probe: any NIMHealthProbe, clock: any VoiceClock, ttl: Double) {
        self.probe = probe
        self.clock = clock
        self.ttl = ttl
    }

    func current() async -> NIMProbeResult {
        let now = clock.now()
        if let cached, now - cached.at < ttl { return cached.result }
        if let inflight { return await inflight.value }
        let probe = self.probe
        let task = Task { await probe.check() }
        inflight = task
        let result = await task.value
        inflight = nil
        cached = (result, clock.now())
        return result
    }
}
