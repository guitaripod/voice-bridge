import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import Synchronization

public typealias FakeNIMScript = @Sendable (FakeNIMSession) async -> Void

/// A NIM stand-in on a loopback port: the realtime socket at `/v1/realtime` driven by a script per
/// connection, and the health route. Tests use it with scripts, `voice-probe fake-nim` with the demo.
public final class FakeNIMServer: Sendable {
    public struct Options: Sendable {
        public var upgradeDelay: @Sendable (Int) -> Double
        public var refuse: @Sendable (Int) -> Bool

        public init(
            upgradeDelay: @escaping @Sendable (Int) -> Double = { _ in 0 },
            refuse: @escaping @Sendable (Int) -> Bool = { _ in false }
        ) {
            self.upgradeDelay = upgradeDelay
            self.refuse = refuse
        }
    }

    private struct State {
        var sessions: [FakeNIMSession] = []
        var attempts = 0
        var healthStatus = 200
        var healthBody = #"{"triton_status":"ready"}"#
        var port = 0
        var runner: Task<Void, Never>?
    }

    private let options: Options
    private let script: FakeNIMScript
    private let state = Mutex(State())

    public init(options: Options = Options(), script: @escaping FakeNIMScript = { _ in }) {
        self.options = options
        self.script = script
    }

    public var sessions: [FakeNIMSession] { state.withLock { $0.sessions } }
    public var attempts: Int { state.withLock { $0.attempts } }
    public var port: Int { state.withLock { $0.port } }
    public var url: String { "ws://127.0.0.1:\(port)/v1/realtime" }

    public func setHealth(status: Int, body: String) {
        state.withLock {
            $0.healthStatus = status
            $0.healthBody = body
        }
    }

    @discardableResult
    public func start(port requested: Int = 0) async -> Int {
        let router = Router(context: BasicRequestContext.self)
        router.get("v1/realtime/health") { [self] _, _ -> Response in
            let (status, body) = state.withLock { ($0.healthStatus, $0.healthBody) }
            return Response(
                status: .init(code: status), headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: body)))
        }
        let socketRouter = Router(context: BasicWebSocketRequestContext.self)
        socketRouter.ws(
            "v1/realtime",
            shouldUpgrade: { [self] _, _ in
                let attempt = state.withLock { state -> Int in
                    state.attempts += 1
                    return state.attempts - 1
                }
                if options.refuse(attempt) { return .dontUpgrade }
                let delay = options.upgradeDelay(attempt)
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                return .upgrade([:])
            }
        ) { [self] inbound, outbound, _ in
            await serve(inbound: inbound, outbound: outbound)
        }
        let (ports, announce) = AsyncStream.makeStream(of: Int.self)
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(
                webSocketRouter: socketRouter, configuration: .init(ws: .init(maxFrameSize: 1 << 22))),
            configuration: .init(address: .hostname("127.0.0.1", port: requested)),
            onServerRunning: { channel in announce.yield(channel.localAddress?.port ?? 0) })
        let runner = Task {
            do { try await app.runService(gracefulShutdownSignals: []) } catch {}
        }
        var bound = 0
        for await value in ports {
            bound = value
            break
        }
        state.withLock {
            $0.port = bound
            $0.runner = runner
        }
        return bound
    }

    public func stop() async {
        let runner = state.withLock { $0.runner }
        runner?.cancel()
        await runner?.value
    }

    private func serve(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async {
        let session = state.withLock { state -> FakeNIMSession in
            let session = FakeNIMSession(index: state.sessions.count, writer: outbound)
            state.sessions.append(session)
            return session
        }
        await session.emit(.sessionCreated)
        let scripted = Task { await script(session) }
        let reader = Task {
            do {
                for try await message in inbound.messages(maxSize: 1 << 22) {
                    guard case .text(let text) = message else { continue }
                    session.record(text)
                    let type = FakeNIMReceived(text: text).type
                    if type == "session.update" { await session.emit(.sessionUpdated) }
                    if type == "session.close" {
                        await session.emit(.sessionEnd)
                        session.close()
                    }
                }
            } catch {}
            session.inboundEnded()
            session.close()
        }
        for await _ in session.closeSignal {}
        scripted.cancel()
        reader.cancel()
    }
}
