import Foundation
import SetupKit
import VoiceKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GatewayAnswer<Value: Sendable>: Sendable {
    case answered(Value)
    case notRunning
    case unreadable(String)
}

extension GatewayAnswer: Equatable where Value: Equatable {}

/// The gateway that is running now, asked over its own routes: the only honest source for whether a
/// call, a download or an engine load is going on, since that state lives in its process.
public protocol RunningGateway: Sendable {
    func health() async -> GatewayAnswer<VoiceHealth>
    func setup() async -> GatewayAnswer<[SetupReport]>
}

public struct HTTPRunningGateway: RunningGateway {
    public let port: Int
    public let password: String?
    public let timeout: Double

    public init(port: Int, password: String?, timeout: Double = 5) {
        self.port = port
        self.password = password
        self.timeout = timeout
    }

    public init(environment: [String: String]) {
        let config = GatewayConfig(environment: environment)
        self.init(port: config.port, password: config.password)
    }

    public func health() async -> GatewayAnswer<VoiceHealth> {
        await get(VoiceWire.healthPath) { try JSONDecoder().decode(VoiceHealth.self, from: $0) }
    }

    public func setup() async -> GatewayAnswer<[SetupReport]> {
        let answer = await get(SetupWire.setupPath) { try SetupCodec.decode([SetupReport].self, from: $0) }
        if case .unreadable(let reason) = answer, reason == Self.missing { return .answered([]) }
        return answer
    }

    private static let missing = "HTTP 404"

    private func get<Value: Sendable>(_ path: String, decode: (Data) throws -> Value) async -> GatewayAnswer<Value> {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return .unreadable("bad address") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let password { request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return .unreadable(status == 401 ? "the password was refused" : "HTTP \(status)")
            }
            return .answered(try decode(data))
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .notRunning
        } catch {
            return .unreadable("\(error.localizedDescription)")
        }
    }
}
