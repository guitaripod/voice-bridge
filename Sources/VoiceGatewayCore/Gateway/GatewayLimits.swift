import VoiceKit

/// Every threshold the contract names. A test may shrink one; production uses `contract`.
public struct GatewayLimits: Sendable, Equatable {
    public var runawaySpeechSeconds: Double
    public var runawayTailSeconds: Double
    public var loopWordRun: Int
    public var loopRepeats: Int
    public var loopWindowCharacters: Int
    public var engineSilenceSeconds: Double
    public var clientSilenceSeconds: Double
    public var helloTimeoutSeconds: Double
    public var recycleAudioSeconds: Double
    public var recycleTurns: Int
    public var replayBufferSeconds: Double
    public var quietSeconds: Double
    public var faultWindowSeconds: Double
    public var nimConnectTimeoutSeconds: Double
    public var tickSeconds: Double
    public var healthCacheSeconds: Double
    public var transcriptGraceSeconds: Double
    public var engineFrameSeconds: Double = 2
    public var engineWatchSeconds: Double = 0.25

    public static let contract = GatewayLimits(
        runawaySpeechSeconds: 25,
        runawayTailSeconds: 3,
        loopWordRun: 4,
        loopRepeats: 3,
        loopWindowCharacters: 200,
        engineSilenceSeconds: 10,
        clientSilenceSeconds: 15,
        helloTimeoutSeconds: 15,
        recycleAudioSeconds: 90,
        recycleTurns: 4,
        replayBufferSeconds: 2,
        quietSeconds: 0.5,
        faultWindowSeconds: 60,
        nimConnectTimeoutSeconds: 5,
        tickSeconds: 0.1,
        healthCacheSeconds: 2,
        transcriptGraceSeconds: 3)
}

/// PCM16 mono at the wire's sample rate.
public enum PCM {
    public static let bytesPerSecond = VoiceWire.sampleRate * 2

    public static func seconds(bytes: Int) -> Double {
        Double(bytes) / Double(bytesPerSecond)
    }

    public static func bytes(seconds: Double) -> Int {
        Int(seconds * Double(bytesPerSecond)) & ~1
    }
}
