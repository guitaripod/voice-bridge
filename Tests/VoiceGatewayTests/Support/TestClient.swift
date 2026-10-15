import Foundation
import HTTPTypes
import Synchronization
import VoiceGatewayCore
import VoiceKit

/// A call client for tests: keeps every frame it receives and waits for the ones a test cares about.
final class TestClient: Sendable {
    struct Log {
        var messages: [VoiceServerMessage] = []
        var audio = Data()
        var closed = false
    }

    final class LogBox: Sendable {
        let mutex = Mutex(Log())

        func withLock<R: Sendable>(_ body: (inout Log) -> R) -> R { mutex.withLock { body(&$0) } }
    }

    let channel: WSChannel
    private let log = LogBox()

    init(channel: WSChannel) {
        self.channel = channel
        let stream = channel.inbound
        let log = self.log
        Task {
            for await item in stream {
                switch item {
                case .text(let text):
                    if let message = try? VoiceCodec.decodeServer(text) { log.withLock { $0.messages.append(message) } }
                case .binary(let data): log.withLock { $0.audio.append(data) }
                case .closed: log.withLock { $0.closed = true }
                }
            }
            log.withLock { $0.closed = true }
        }
    }

    static func connect(port: Int, token: String? = nil) async throws -> TestClient {
        var headers = HTTPFields()
        if let token { headers[.authorization] = "Bearer \(token)" }
        return TestClient(channel: try await WSChannel.connect(url: "ws://127.0.0.1:\(port)/call", headers: headers))
    }

    var messages: [VoiceServerMessage] { log.withLock { $0.messages } }
    var audio: Data { log.withLock { $0.audio } }
    var isClosed: Bool { log.withLock { $0.closed } }

    func send(_ message: VoiceClientMessage) {
        if let text = try? VoiceCodec.encode(message) { channel.send(text: text) }
    }

    func sendAudio(seconds: Double, frameBytes: Int = VoiceWire.preferredChunkBytes) {
        var remaining = PCM.bytes(seconds: seconds)
        while remaining > 0 {
            let size = min(frameBytes, remaining)
            channel.send(binary: Data(count: size))
            remaining -= size
        }
    }

    func hello(version: Int = VoiceWire.version) {
        send(.hello(.init(v: version, client: .linux, app: "tests")))
    }

    func waitFor(timeout: Double = 5, _ match: @Sendable (VoiceServerMessage) -> Bool) async -> VoiceServerMessage? {
        let found = await eventually(timeout: timeout) { messages.contains(where: match) }
        return found ? messages.first(where: match) : nil
    }

    func waitClosed(timeout: Double = 5) async -> Bool {
        await eventually(timeout: timeout) { isClosed }
    }

    func count(where match: (VoiceServerMessage) -> Bool) -> Int {
        messages.filter(match).count
    }

    var phases: [VoicePhase] {
        messages.compactMap { if case .phase(let phase, _) = $0 { phase } else { nil } }
    }

    func close() async {
        await channel.close()
    }
}
