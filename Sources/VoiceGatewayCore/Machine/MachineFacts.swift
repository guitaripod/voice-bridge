import Foundation

/// Everything the doctor and the engine manager know about the machine at one moment.
struct MachineFacts: Sendable, Equatable {
    var gpu: GPUFacts?
    var os: OSRelease
    var docker: DockerState
    var toolkitInstalled: Bool
    var cdi: Bool
    var imageBytes: Int64?
    var model: ModelStatus
    var container: ContainerState
    var nim: NIMProbeResult

    var imagePresent: Bool { imageBytes != nil }
    var cardIsEnough: Bool { (gpu?.totalMB ?? 0) >= VoiceRequirements.minimumCardMB }
    var dockerReady: Bool { docker == .ready }

    var setupComplete: Bool {
        gpu != nil && cardIsEnough && dockerReady && cdi && model.valid && imagePresent
    }
}
