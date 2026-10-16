import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum UpdateWire {
    public static let path = "/update"
    public static let defaultReleaseBase = "https://github.com/guitaripod/voice-bridge/releases/latest/download"
}

/// The answer of `GET /update`. `latest` is `nil` while no release list has ever been read, and `behind`
/// is then false: not knowing is never reported as being out of date.
public struct UpdateInfo: Codable, Sendable, Equatable {
    public var current: String
    public var latest: String?
    public var behind: Bool

    public init(current: String, latest: String?, behind: Bool) {
        self.current = current
        self.latest = latest
        self.behind = behind
    }
}

public enum ReleaseList {
    public typealias Fetch = @Sendable () async -> String?

    public static func url(base: String) -> URL? {
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + "/latest.txt")
    }

    public static func fetcher(base: String, timeout: Double = 5) -> Fetch {
        { await download(url(base: base), timeout: timeout) }
    }

    public static func latest(_ fetch: Fetch) async -> ReleaseVersion? {
        await fetch().flatMap(ReleaseVersion.init)
    }

    private static func download(_ url: URL?, timeout: Double) async -> String? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200, data.count < 256
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reads the release list at most every few hours and remembers the last version it saw, so an app
/// asking `GET /update` costs nothing, and a machine that is offline keeps answering with what it knew.
actor UpdateChecker {
    static let freshSeconds = 6.0 * 3_600
    static let retrySeconds = 10.0 * 60

    private let fetch: ReleaseList.Fetch
    private let clock: any VoiceClock
    private let current: String
    private var latest: ReleaseVersion?
    private var nextCheck: Double?
    private var inflight: Task<ReleaseVersion?, Never>?

    init(current: String = GatewayInfo.version, clock: any VoiceClock, fetch: @escaping ReleaseList.Fetch) {
        self.current = current
        self.clock = clock
        self.fetch = fetch
    }

    func info() async -> UpdateInfo {
        if nextCheck.map({ clock.now() >= $0 }) ?? true { await refresh() }
        return UpdateInfo(current: current, latest: latest?.description, behind: isBehind)
    }

    private var isBehind: Bool {
        guard let latest, let running = ReleaseVersion(current) else { return false }
        return running < latest
    }

    private func refresh() async {
        if let inflight {
            _ = await inflight.value
            return
        }
        let fetch = self.fetch
        let task = Task { await ReleaseList.latest(fetch) }
        inflight = task
        let found = await task.value
        inflight = nil
        if let found {
            latest = found
            nextCheck = clock.now() + Self.freshSeconds
        } else {
            nextCheck = clock.now() + Self.retrySeconds
        }
    }
}
