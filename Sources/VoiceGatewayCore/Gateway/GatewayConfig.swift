import Foundation
import Logging
import VoiceKit

/// How the person's words reach the agent: when the model calls `send_to_agent`, or as soon as each
/// final transcript completes.
public enum DispatchMode: String, Sendable, Equatable {
    case tool
    case transcripts
}

public struct GatewayConfig: Sendable, Equatable {
    public static let defaultNIMURL = "ws://127.0.0.1:9000/v1/realtime"

    public var port: Int
    public var nimURL: String
    public var password: String?
    public var logLevel: Logger.Level
    public var dispatch: DispatchMode
    public var engine: EngineMode
    public var idleStopMinutes: Double
    public var releaseBase: String

    public init(
        port: Int = VoiceWire.port, nimURL: String = GatewayConfig.defaultNIMURL,
        password: String? = nil, logLevel: Logger.Level = .info,
        dispatch: DispatchMode = .tool, engine: EngineMode = .external, idleStopMinutes: Double = 10,
        releaseBase: String = UpdateWire.defaultReleaseBase
    ) {
        self.port = port
        self.nimURL = nimURL
        self.password = password
        self.logLevel = logLevel
        self.dispatch = dispatch
        self.engine = engine
        self.idleStopMinutes = idleStopMinutes
        self.releaseBase = releaseBase
    }

    public init(environment: [String: String]) {
        func value(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(
            port: value("VOICE_PORT").flatMap(Int.init) ?? VoiceWire.port,
            nimURL: value("VOICE_NIM_URL") ?? GatewayConfig.defaultNIMURL,
            password: value("VOICE_PASSWORD"),
            logLevel: value("VOICE_LOG_LEVEL").flatMap { Logger.Level(rawValue: $0.lowercased()) } ?? .info,
            dispatch: value("VOICE_DISPATCH").flatMap { DispatchMode(rawValue: $0.lowercased()) } ?? .tool,
            engine: value("VOICE_ENGINE").flatMap { EngineMode(rawValue: $0.lowercased()) } ?? .auto,
            idleStopMinutes: value("VOICE_IDLE_STOP_MINUTES").flatMap(Double.init).flatMap { $0 >= 0 ? $0 : nil } ?? 10,
            releaseBase: value("VOICE_RELEASE_BASE") ?? UpdateWire.defaultReleaseBase)
    }
}

public enum GatewayInfo {
    public static let version = "0.2.0"
    public static let modelName = "NemotronLabs VoiceChat 11B"
}
