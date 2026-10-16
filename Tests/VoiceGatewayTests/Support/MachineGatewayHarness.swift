import Foundation
import Hummingbird
import SetupKit
import Testing
@testable import VoiceGatewayCore
import VoiceKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A gateway with machine services on a fake host, a fake NIM for the call itself, and a manual clock.
final class MachineGatewayHarness: Sendable {
    let nim: FakeNIMServer
    let clock = ManualClock()
    let host: FakeHost
    let root: FakeRoot
    let probe: FakeNIMProbe
    let services: MachineServices
    let gateway: Gateway
    let port: Int
    private let runner: Task<Void, Never>

    private init(
        nim: FakeNIMServer, host: FakeHost, root: FakeRoot, probe: FakeNIMProbe, services: MachineServices, gateway: Gateway, port: Int,
        runner: Task<Void, Never>, clock: ManualClock
    ) {
        self.nim = nim
        self.host = host
        self.root = root
        self.probe = probe
        self.services = services
        self.gateway = gateway
        self.port = port
        self.runner = runner
    }

    static func start(
        _ machine: FakeMachine = FakeMachine(), mode: EngineMode = .managed, nim probeResult: NIMProbeResult = .down("not reachable"),
        password: String? = nil, runner customRunner: (any CommandRunner)? = nil, root customRoot: FakeRoot? = nil
    ) async -> MachineGatewayHarness {
        let nim = FakeNIMServer()
        await nim.start()
        let clock = ManualClock()
        let host = FakeHost(machine)
        let root = customRoot ?? FakeRoot(machine)
        let probe = FakeNIMProbe(probeResult)
        let services = MachineServices(
            runner: customRunner ?? host, paths: root.paths, nim: probe, settings: EngineSettings(mode: mode), clock: clock)
        let gateway = Gateway(
            config: GatewayConfig(port: 0, nimURL: nim.url, password: password, engine: mode), machine: services, clock: clock)
        let (ports, announce) = AsyncStream.makeStream(of: Int.self)
        let app = GatewayApp.make(
            gateway: gateway, host: "127.0.0.1", port: 0, onServerRunning: { channel in announce.yield(channel.localAddress?.port ?? 0) })
        let task = Task {
            do { try await app.runService(gracefulShutdownSignals: []) } catch {}
        }
        var port = 0
        for await value in ports {
            port = value
            break
        }
        return MachineGatewayHarness(
            nim: nim, host: host, root: root, probe: probe, services: services, gateway: gateway, port: port, runner: task, clock: clock)
    }

    var clockHandle: ManualClock { gateway.clock as! ManualClock }

    func stop() async {
        runner.cancel()
        await runner.value
        await nim.stop()
    }

    func request(_ method: String, _ path: String, body: String? = nil, token: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = Data(body.utf8) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func health() async throws -> VoiceHealth {
        await services.facts.forget()
        clockHandle.advance(by: 3)
        let (status, body) = try await request("GET", "/health")
        #expect(status == 200)
        return try JSONDecoder().decode(VoiceHealth.self, from: body)
    }

    func connect(token: String? = nil) async throws -> TestClient {
        try await TestClient.connect(port: port, token: token)
    }

    func advance(until condition: @Sendable () async -> Bool, timeout: Double = 8, step: Double = 0.5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            clockHandle.advance(by: step)
            try? await Task.sleep(for: .milliseconds(4))
        }
        return await condition()
    }
}
