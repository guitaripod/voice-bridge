import Foundation
import Logging
import VoiceKit

public struct GatewayConfig: Sendable, Equatable {
    public static let defaultNIMURL = "ws://127.0.0.1:9000/v1/realtime"

    public var port: Int
    public var nimURL: String
    public var password: String?
    public var logLevel: Logger.Level

    public init(
        port: Int = VoiceWire.port, nimURL: String = GatewayConfig.defaultNIMURL,
        password: String? = nil, logLevel: Logger.Level = .info
    ) {
        self.port = port
        self.nimURL = nimURL
        self.password = password
        self.logLevel = logLevel
    }

    public init(environment: [String: String]) {
        func value(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(
            port: value("VOICE_PORT").flatMap(Int.init) ?? VoiceWire.port,
            nimURL: value("VOICE_NIM_URL") ?? GatewayConfig.defaultNIMURL,
            password: value("VOICE_PASSWORD"),
            logLevel: value("VOICE_LOG_LEVEL").flatMap { Logger.Level(rawValue: $0.lowercased()) } ?? .info)
    }
}

public enum GatewayInfo {
    public static let version = "0.1.0"
    public static let modelName = "NemotronLabs VoiceChat 11B"
}
