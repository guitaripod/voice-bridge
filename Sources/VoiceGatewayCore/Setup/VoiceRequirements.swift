import Foundation

/// What the voice model needs from a machine and the names it runs under.
public enum VoiceRequirements {
    public static let minimumCardMB = 80_000
    public static let freeVRAMMB = 70_000
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

    public static let capability = "voice"
    public static let downloadModelFix = "voice.downloadModel"
    public static let pullImageFix = "voice.pullImage"
    public static let installDockerFix = "voice.installDocker"
    public static let generateCDIFix = "voice.generateCDI"
}
