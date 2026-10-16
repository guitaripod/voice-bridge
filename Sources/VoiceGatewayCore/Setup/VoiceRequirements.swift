import Foundation

/// What the voice model needs from a machine and the names it runs under.
public enum VoiceRequirements {
    /// The container measured 58 GB in use with the default engine shares below; a card under 64 GB has no
    /// headroom for it, and the free memory needed to start is that measure plus a margin.
    public static let minimumCardMB = 64_000
    public static let freeVRAMMB = 62_000
    public static let defaultLLMMemUtil = 0.30
    public static let defaultTTSMemUtil = 0.25
    public static let memUtilRange = 0.1...0.6
    public static let modelBytes: Int64 = 46_868_000_000
    public static let imageBytes: Int64 = 22_500_000_000
    public static let modelMinutes = 15
    public static let imageMinutes = 10

    public static let imageName = "nvcr.io/nim/nvidia/nemotron-labs-voicechat:latest"
    public static let containerName = "nemotron-labs-voicechat"
    public static let modelReference = "nim/nvidia/nemotron-labs-voicechat:1.0.0"
    public static let modelFolder = "nemotron-labs-voicechat_v1.0.0"
    public static let tritonModel = "nemotron-voicechat"
    public static let nimPort = 9000

    public static let typicalLoadSeconds = 240.0
    public static let loadTimeoutSeconds = 480.0

    /// Free space is counted in mebibytes, the unit `df` and `nvidia-smi` report, rounded up.
    public static func megabytes(_ bytes: Int64) -> Int {
        Int((bytes + 1_048_575) / 1_048_576)
    }

    public static let capability = "voice"
    public static let downloadModelFix = "voice.downloadModel"
    public static let pullImageFix = "voice.pullImage"
    public static let installDockerFix = "voice.installDocker"
    public static let generateCDIFix = "voice.generateCDI"
}
