import Foundation
import HTTPTypes
import HummingbirdWSClient
import Logging
import NIOCore

public enum WSChannelError: Error, Sendable, CustomStringConvertible {
    case timedOut
    case closed

    public var description: String {
        switch self {
        case .timedOut: "websocket connect timed out"
        case .closed: "websocket closed"
        }
    }
}

/// A WebSocket client as plain async streams: frames in, frames out, close. The NIM leg, the probe
/// and the test client all use it.
public final class WSChannel: Sendable {
    public enum Inbound: Sendable, Equatable {
        case text(String)
        case binary(Data)
        case closed(String?)
    }

    private enum Outgoing: Sendable {
        case text(String)
        case binary(Data)
    }

    public let inbound: AsyncStream<Inbound>
    private let outgoing: AsyncStream<Outgoing>.Continuation
    private let runner: Task<Void, Never>

    private init(inbound: AsyncStream<Inbound>, outgoing: AsyncStream<Outgoing>.Continuation, runner: Task<Void, Never>) {
        self.inbound = inbound
        self.outgoing = outgoing
        self.runner = runner
    }

    public static func connect(
        url: String, headers: HTTPFields = [:], maxFrameSize: Int = 1 << 22, timeout: Double = 5,
        logger: Logger = Logger(label: "voice.ws")
    ) async throws -> WSChannel {
        let (inStream, inbound) = AsyncStream.makeStream(of: Inbound.self)
        let (outStream, outgoing) = AsyncStream.makeStream(of: Outgoing.self)
        let (gateStream, gate) = AsyncStream.makeStream(of: Result<Void, any Error>.self)
        let runner = Task {
            do {
                let client = WebSocketClient(
                    url: url, configuration: .init(maxFrameSize: maxFrameSize, additionalHeaders: headers),
                    logger: logger
                ) { socketIn, socketOut, _ in
                    gate.yield(.success(()))
                    await pump(socketIn, socketOut, outStream, inbound, maxFrameSize)
                }
                try await client.run()
            } catch {
                gate.yield(.failure(error))
                inbound.yield(.closed("\(error)"))
            }
            inbound.finish()
            gate.finish()
        }
        let channel = WSChannel(inbound: inStream, outgoing: outgoing, runner: runner)
        do {
            try await awaitOpen(gateStream, timeout: timeout)
        } catch {
            runner.cancel()
            throw error
        }
        return channel
    }

    public func send(text: String) {
        outgoing.yield(.text(text))
    }

    public func send(binary: Data) {
        outgoing.yield(.binary(binary))
    }

    /// Asks for an orderly close, then gives the peer a second to answer before cutting the task.
    public func close() async {
        outgoing.finish()
        let runner = self.runner
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(1))
            runner.cancel()
        }
        await runner.value
        watchdog.cancel()
    }

    private static func awaitOpen(_ gate: AsyncStream<Result<Void, any Error>>, timeout: Double) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await result in gate { return try result.get() }
                throw WSChannelError.closed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw WSChannelError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private static func pump(
        _ socketIn: WebSocketInboundStream, _ socketOut: WebSocketOutboundWriter,
        _ outStream: AsyncStream<Outgoing>, _ inbound: AsyncStream<Inbound>.Continuation, _ maxFrameSize: Int
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await item in outStream {
                    do {
                        switch item {
                        case .text(let text): try await socketOut.write(.text(text))
                        case .binary(let data): try await socketOut.write(.binary(ByteBuffer(bytes: data)))
                        }
                    } catch { return }
                }
            }
            group.addTask {
                var reason: String?
                do {
                    for try await message in socketIn.messages(maxSize: maxFrameSize) {
                        switch message {
                        case .text(let text): inbound.yield(.text(text))
                        case .binary(let buffer): inbound.yield(.binary(Data(buffer.readableBytesView)))
                        }
                    }
                } catch {
                    reason = "\(error)"
                }
                inbound.yield(.closed(reason))
            }
            await group.next()
            group.cancelAll()
        }
    }
}
