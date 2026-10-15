import Foundation

public enum NIMInbound: Sendable, Equatable {
    case event(NIMEvent)
    case closed(String?)
}

/// One live socket to the NIM. `events` ends after `.closed`.
public protocol NIMConnection: Sendable {
    var events: AsyncStream<NIMInbound> { get }
    func send(_ text: String)
    func close() async
}

public protocol NIMConnector: Sendable {
    func connect(url: String, timeout: Double) async throws -> any NIMConnection
}

public struct WebSocketNIMConnector: NIMConnector {
    public init() {}

    public func connect(url: String, timeout: Double) async throws -> any NIMConnection {
        WebSocketNIMConnection(channel: try await WSChannel.connect(url: url, timeout: timeout))
    }
}

final class WebSocketNIMConnection: NIMConnection {
    let events: AsyncStream<NIMInbound>
    private let channel: WSChannel

    init(channel: WSChannel) {
        self.channel = channel
        let source = channel.inbound
        events = AsyncStream { continuation in
            let relay = Task {
                for await item in source {
                    switch item {
                    case .text(let text): continuation.yield(.event(NIMEvent.parse(text)))
                    case .binary: continue
                    case .closed(let reason): continuation.yield(.closed(reason))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }

    func send(_ text: String) {
        channel.send(text: text)
    }

    func close() async {
        await channel.close()
    }
}
