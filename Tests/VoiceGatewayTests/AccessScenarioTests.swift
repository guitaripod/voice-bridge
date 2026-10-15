import Foundation
import Testing
import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct AccessScenarioTests {
    @Test func versionMismatchGetsAnErrorFrameThenClose() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.hello(version: 2)
        #expect(await client.waitForError("version"))
        #expect(await client.waitClosed())
        #expect(harness.nim.attempts == 0)
        #expect(harness.gateway.calls == 0)
    }

    @Test func firstFrameMustBeHello() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.send(.bye)
        #expect(await client.waitForError("hello"))
        #expect(await client.waitClosed())
    }

    @Test func aSecondCallerIsToldBusy() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let first = try await harness.call()
        _ = await harness.nimSession()
        let second = try await harness.connect()
        second.hello()
        #expect(await second.waitForError("busy"))
        #expect(await second.waitClosed())
        #expect(harness.nim.attempts == 1)
        #expect(!first.isClosed)
        #expect(harness.gateway.calls == 1)
        await first.close()
        #expect(await eventually { harness.gateway.calls == 0 })
        let third = try await harness.call()
        await third.close()
    }

    @Test func passwordGuardsCallAndHealth() async throws {
        let harness = await GatewayHarness.start(password: "s3cret")
        defer { Task { await harness.stop() } }

        await #expect(throws: (any Error).self) { _ = try await harness.connect() }
        await #expect(throws: (any Error).self) { _ = try await harness.connect(token: "wrong") }
        let good = try await harness.connect(token: "s3cret")
        good.hello()
        #expect(await good.waitFor { if case .ready = $0 { true } else { false } } != nil)
        await good.close()

        #expect(try await harness.get("/health").0 == 401)
        #expect(try await harness.get("/health", token: "wrong").0 == 401)
        #expect(try await harness.get("/health", token: "s3cret").0 == 200)
    }

    @Test func noPasswordMeansOpen() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        #expect(try await harness.get("/health").0 == 200)
    }
}
