import Foundation
import VoiceKit

enum ClientFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// Everything the gateway sends to the client goes through here, so nothing in a call ever waits
/// on the client's socket. Order is kept; `finish` lets what is queued drain.
final class ClientOutbox: Sendable {
    private let stream: AsyncStream<ClientFrame>
    private let continuation: AsyncStream<ClientFrame>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: ClientFrame.self)
    }

    func send(_ message: VoiceServerMessage) {
        guard let text = try? VoiceCodec.encode(message) else { return }
        continuation.yield(.text(text))
    }

    func sendAudio(_ pcm: Data) {
        continuation.yield(.binary(pcm))
    }

    func finish() {
        continuation.finish()
    }

    func run(write: @Sendable (ClientFrame) async throws -> Void) async {
        for await frame in stream {
            do { try await write(frame) } catch { return }
        }
    }
}
