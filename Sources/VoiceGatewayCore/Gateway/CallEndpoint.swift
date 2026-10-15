import Foundation
import HummingbirdWebSocket
import NIOCore
import VoiceKit

extension Gateway {
    /// Serves one `/call` socket: handshake, the one-call-at-a-time rule, then the call itself.
    func serveCall(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async {
        let outbox = ClientOutbox()
        let (frames, framesIn) = AsyncStream.makeStream(of: ClientFrame.self)
        let writer = Task {
            await outbox.run { frame in
                switch frame {
                case .text(let text): try await outbound.write(.text(text))
                case .binary(let pcm): try await outbound.write(.binary(ByteBuffer(bytes: pcm)))
                }
            }
        }
        let socketReader = Task {
            do {
                for try await message in inbound.messages(maxSize: VoiceWire.maxChunkBytes * 4) {
                    switch message {
                    case .text(let text): framesIn.yield(.text(text))
                    case .binary(let buffer): framesIn.yield(.binary(Data(buffer.readableBytesView)))
                    }
                }
            } catch {
                logger.debug("client socket ended", metadata: ["error": "\(error)"])
            }
            framesIn.finish()
        }
        await withTaskCancellationHandler {
            await call(frames: FrameReader(frames), outbox: outbox)
        } onCancel: {
            socketReader.cancel()
            outbox.finish()
        }
        outbox.finish()
        await writer.value
        socketReader.cancel()
    }

    private func call(frames: FrameReader, outbox: ClientOutbox) async {
        guard let hello = await readHello(frames, outbox: outbox) else { return }
        guard hello.v == VoiceWire.version else {
            outbox.send(
                .error(
                    code: "version",
                    message: "This gateway speaks voice protocol \(VoiceWire.version), the client sent \(hello.v)."))
            return
        }
        guard acquire() else {
            outbox.send(.error(code: "busy", message: "A call is already in progress."))
            return
        }
        defer { release() }
        logger.info("call", metadata: ["client": "\(hello.client.rawValue)", "app": "\(hello.app)"])
        let session = CallSession(
            nimURL: config.nimURL, connector: connector, clock: clock, limits: limits, outbox: outbox, logger: logger)
        guard await session.open() else { return }
        await session.begin()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while let frame = await frames.next() { await session.handle(frame) }
                await session.clientGone()
            }
            group.addTask { await session.waitFinished() }
            await group.next()
            group.cancelAll()
        }
        await session.finish()
    }

    private func readHello(_ frames: FrameReader, outbox: ClientOutbox) async -> VoiceClientMessage.Hello? {
        let deadline = clock.now() + limits.helloTimeoutSeconds
        let clock = self.clock
        let first: ClientFrame? = await withTaskGroup(of: ClientFrame?.self) { group in
            group.addTask { await frames.next() }
            group.addTask {
                try? await clock.sleep(until: deadline)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        guard case .text(let text)? = first, case .hello(let hello)? = try? VoiceCodec.decodeClient(text) else {
            if first != nil { outbox.send(.error(code: "hello", message: "The first frame must be hello.")) }
            return nil
        }
        return hello
    }
}

/// Hands the client's frames to whichever task is reading. Only one task reads at a time: the
/// hello race ends before the call loop starts.
final class FrameReader: @unchecked Sendable {
    private var iterator: AsyncStream<ClientFrame>.AsyncIterator

    init(_ stream: AsyncStream<ClientFrame>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> ClientFrame? {
        await iterator.next()
    }
}
