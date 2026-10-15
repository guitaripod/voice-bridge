import Foundation
import Hummingbird
import Synchronization
import Testing
import VoiceGatewayCore
import VoiceKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A gateway on an ephemeral loopback port in front of a scripted fake NIM, with a manual clock.
final class GatewayHarness: Sendable {
    let nim: FakeNIMServer
    let clock: ManualClock
    let gateway: Gateway
    let port: Int
    private let runner: Task<Void, Never>

    private init(nim: FakeNIMServer, clock: ManualClock, gateway: Gateway, port: Int, runner: Task<Void, Never>) {
        self.nim = nim
        self.clock = clock
        self.gateway = gateway
        self.port = port
        self.runner = runner
    }

    static func start(
        options: FakeNIMServer.Options = .init(), password: String? = nil, limits: GatewayLimits = .contract,
        nimURL: String? = nil, script: @escaping FakeNIMScript = { _ in }
    ) async -> GatewayHarness {
        let nim = FakeNIMServer(options: options, script: script)
        await nim.start()
        let clock = ManualClock()
        let gateway = Gateway(
            config: GatewayConfig(port: 0, nimURL: nimURL ?? nim.url, password: password), limits: limits, clock: clock)
        let (ports, announce) = AsyncStream.makeStream(of: Int.self)
        let app = GatewayApp.make(
            gateway: gateway, host: "127.0.0.1", port: 0,
            onServerRunning: { channel in announce.yield(channel.localAddress?.port ?? 0) })
        let runner = Task {
            do { try await app.runService(gracefulShutdownSignals: []) } catch {}
        }
        var port = 0
        for await value in ports {
            port = value
            break
        }
        return GatewayHarness(nim: nim, clock: clock, gateway: gateway, port: port, runner: runner)
    }

    func connect(token: String? = nil) async throws -> TestClient {
        try await TestClient.connect(port: port, token: token)
    }

    /// Connects, says hello and waits for `ready`.
    func call() async throws -> TestClient {
        let client = try await connect()
        client.hello()
        let ready = await client.waitFor { if case .ready = $0 { true } else { false } }
        #expect(ready != nil, "no ready frame")
        return client
    }

    func get(_ path: String, token: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func advance(until condition: @Sendable () async -> Bool, timeout: Double = 5, step: Double = 0.2) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            clock.advance(by: step)
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func stop() async {
        runner.cancel()
        await runner.value
        await nim.stop()
    }
}
