import Foundation

/// The last couple of seconds of microphone audio that arrived while the voice session was being
/// swapped. Older audio falls off the front.
struct ReplayBuffer: Sendable {
    private let capacity: Int
    private(set) var audio = Data()

    init(seconds: Double) {
        capacity = PCM.bytes(seconds: seconds)
    }

    mutating func append(_ pcm: Data) {
        audio.append(pcm)
        if audio.count > capacity {
            audio = Data(audio.suffix(capacity))
        }
    }

    mutating func drain() -> Data {
        defer { audio = Data() }
        return audio
    }
}
