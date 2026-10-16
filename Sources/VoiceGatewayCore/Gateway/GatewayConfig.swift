import Foundation
import Logging
import VoiceKit

/// How the person's words reach the agent: when the model calls `send_to_agent`, or as soon as each
/// final transcript completes.
public enum DispatchMode: String, Sendable, Equatable {
    case tool
    case transcripts
}

/// What the model does with its voice. `muted`: it only listens and transcribes, no tools are registered and
/// nothing it says reaches the client. `model`: it speaks and may call tools, which is for experiments.
public enum SpeechMode: String, Sendable, Equatable {
    case muted
    case model
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
    public var speech: SpeechMode
    public var llmMemUtil: Double
    public var ttsMemUtil: Double

    public init(
        port: Int = VoiceWire.port, nimURL: String = GatewayConfig.defaultNIMURL,
        password: String? = nil, logLevel: Logger.Level = .info,
        dispatch: DispatchMode = .transcripts, engine: EngineMode = .external, idleStopMinutes: Double = 10,
        releaseBase: String = UpdateWire.defaultReleaseBase, speech: SpeechMode = .muted,
        llmMemUtil: Double = VoiceRequirements.defaultLLMMemUtil, ttsMemUtil: Double = VoiceRequirements.defaultTTSMemUtil
    ) {
        self.port = port
        self.nimURL = nimURL
        self.password = password
        self.logLevel = logLevel
        self.dispatch = dispatch
        self.engine = engine
        self.idleStopMinutes = idleStopMinutes
        self.releaseBase = releaseBase
        self.speech = speech
        self.llmMemUtil = llmMemUtil
        self.ttsMemUtil = ttsMemUtil
    }

    /// A muted model has no tools to call, so tool dispatch could never send anything: transcripts decide.
    public var effectiveDispatch: DispatchMode { speech == .muted ? .transcripts : dispatch }

    public init(environment: [String: String]) {
        func value(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(
            port: value("VOICE_PORT").flatMap(Int.init) ?? VoiceWire.port,
            nimURL: value("VOICE_NIM_URL") ?? GatewayConfig.defaultNIMURL,
            password: value("VOICE_PASSWORD"),
            logLevel: value("VOICE_LOG_LEVEL").flatMap { Logger.Level(rawValue: $0.lowercased()) } ?? .info,
            dispatch: value("VOICE_DISPATCH").flatMap { DispatchMode(rawValue: $0.lowercased()) } ?? .transcripts,
            engine: value("VOICE_ENGINE").flatMap { EngineMode(rawValue: $0.lowercased()) } ?? .auto,
            idleStopMinutes: value("VOICE_IDLE_STOP_MINUTES").flatMap(Double.init).flatMap { $0 >= 0 ? $0 : nil } ?? 10,
            releaseBase: value("VOICE_RELEASE_BASE") ?? UpdateWire.defaultReleaseBase,
            speech: value("VOICE_SPEECH").flatMap { SpeechMode(rawValue: $0.lowercased()) } ?? .muted,
            llmMemUtil: Self.memUtil(value("VOICE_LLM_MEM_UTIL"), default: VoiceRequirements.defaultLLMMemUtil),
            ttsMemUtil: Self.memUtil(value("VOICE_TTS_MEM_UTIL"), default: VoiceRequirements.defaultTTSMemUtil))
    }

    /// A share of the card's memory is a fraction between 0.1 and 0.6; anything else is ignored.
    static func memUtil(_ text: String?, default fallback: Double) -> Double {
        guard let text, let value = Double(text), VoiceRequirements.memUtilRange.contains(value) else { return fallback }
        return value
    }
}

public enum GatewayInfo {
    public static let version = "0.2.0"
    public static let modelName = "NemotronLabs VoiceChat 11B"
}
