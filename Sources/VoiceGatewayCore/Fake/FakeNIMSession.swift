import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import Synchronization

/// One connection to the fake NIM, as the script sees it: what arrived so far, what to say next.
public final class FakeNIMSession: Sendable {
    public let index: Int
    public let messages: AsyncStream<FakeNIMReceived>
    private let feed: AsyncStream<FakeNIMReceived>.Continuation
    private let log = Mutex<[FakeNIMReceived]>([])
    private let writer: WebSocketOutboundWriter
    private let closing: AsyncStream<Void>.Continuation
    let closeSignal: AsyncStream<Void>

    init(index: Int, writer: WebSocketOutboundWriter) {
        self.index = index
        self.writer = writer
        (messages, feed) = AsyncStream.makeStream(of: FakeNIMReceived.self)
        (closeSignal, closing) = AsyncStream.makeStream(of: Void.self)
    }

    public var received: [FakeNIMReceived] { log.withLock { $0 } }

    public var audioBytesReceived: Int {
        received.filter { $0.type == "input_audio_buffer.append" }.reduce(0) { $0 + ($1.audio?.count ?? 0) }
    }

    public func emit(_ event: FakeNIMEvent) async {
        try? await writer.write(.text(event.json))
    }

    /// Ends the connection from the NIM's side.
    public func close() {
        closing.yield()
        closing.finish()
    }

    func record(_ text: String) {
        let message = FakeNIMReceived(text: text)
        log.withLock { $0.append(message) }
        feed.yield(message)
    }

    func inboundEnded() {
        feed.finish()
    }

    /// The `count`th message of this type (1 for the first), polled until it arrives.
    public func message(_ type: String, count: Int = 1, timeout: Double = 5) async -> FakeNIMReceived? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            let matches = received.filter { $0.type == type }
            if matches.count >= count { return matches[count - 1] }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return nil
    }

    public func waitForAudio(bytes: Int, timeout: Double = 10) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if audioBytesReceived >= bytes { return true }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return false
    }
}
