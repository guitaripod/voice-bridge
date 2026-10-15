import Foundation
import Testing
import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct HealthScenarioTests {
    @Test func readyWhenTritonSaysReady() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let (status, body) = try await harness.get("/health")
        #expect(status == 200)
        let health = try JSONDecoder().decode(VoiceHealth.self, from: body)
        #expect(health.engine == .ready)
        #expect(health.protocolVersion == VoiceWire.version)
        #expect(health.gateway == GatewayInfo.version)
        #expect(health.calls == 0)
        #expect(health.model == GatewayInfo.modelName)
        #expect(health.detail?.isEmpty == false)
    }

    @Test func loadingOn503() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        harness.nim.setHealth(status: 503, body: "")
        #expect(await harness.gateway.health().engine == .loading)
    }

    @Test func downWhenUnreachable() async throws {
        let harness = await GatewayHarness.start(nimURL: "ws://127.0.0.1:1/v1/realtime")
        defer { Task { await harness.stop() } }
        #expect(await harness.gateway.health().engine == .down)
    }

    @Test func busyWhileACallIsHeld() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let health = await harness.gateway.health()
        #expect(health.engine == .busy)
        #expect(health.calls == 1)
        await client.close()
        #expect(await eventually { harness.gateway.calls == 0 })
    }

    @Test func probeIsCachedForTwoSeconds() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        #expect(await harness.gateway.health().engine == .ready)
        harness.nim.setHealth(status: 503, body: "")
        #expect(await harness.gateway.health().engine == .ready)
        harness.clock.advance(by: 1.9)
        #expect(await harness.gateway.health().engine == .ready)
        harness.clock.advance(by: 0.2)
        #expect(await harness.gateway.health().engine == .loading)
    }
}
