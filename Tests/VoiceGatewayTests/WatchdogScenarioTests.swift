import Foundation
import Testing
import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct WatchdogScenarioTests {
    let relaxed: GatewayLimits = {
        var limits = GatewayLimits.contract
        limits.clientSilenceSeconds = 100_000
        limits.helloTimeoutSeconds = 100_000
        return limits
    }()

    @Test func modelTalkingForTwentyFiveSecondsIsARunaway() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        for _ in 0..<7 { await nim.speak(seconds: 4) }
        #expect(await client.waitForDegraded(.runaway, recovering: true))
        #expect(await client.waitForRecycled())
        #expect(await eventually { harness.nim.sessions.count == 2 })
        #expect(await eventually { client.phases.last == .listening })
        #expect(client.audio.count <= PCM.bytes(seconds: 25))
        await client.close()
    }

    @Test func audioLongAfterResponseDoneIsARunaway() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        await nim.emit(.responseDone(status: "completed"))
        await nim.emit(.functionCall(callID: "barrier", name: "agent_status", arguments: "{}"))
        _ = await nim.message("conversation.item.create")
        harness.clock.advance(by: 3.5)
        await nim.speak(seconds: 0.08)
        #expect(await client.waitForDegraded(.runaway, recovering: true))
        #expect(await client.waitForRecycled())
        await client.close()
    }

    @Test func repeatedPhraseIsALoop() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        for _ in 0..<3 { await nim.emit(.transcriptDelta("I will look into it. ")) }
        #expect(await client.waitForDegraded(.loop, recovering: true))
        #expect(await client.waitForRecycled())
        await client.close()
    }

    @Test func mutedWhileRecoveringAndNoModelAudioIsForwarded() async throws {
        let harness = await GatewayHarness.start(options: .init(upgradeDelay: { $0 == 1 ? 0.4 : 0 }), limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.error(code: "inference_error", message: "boom"))
        #expect(await client.waitForDegraded(.engineError, recovering: true))
        await nim.emit(.audio(Data(count: 3_840)))
        #expect(await client.waitForRecycled())
        #expect(client.audio.isEmpty)
        #expect(await eventually { harness.nim.sessions.count == 2 })
        await client.close()
    }

    @Test func nimErrorRecyclesOnceThenStaysDegraded() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let first = await harness.nimSession(0)
        await first.emit(.error(code: "inference_error", message: "boom"))
        #expect(await client.waitForDegraded(.engineError, recovering: true))
        #expect(await client.waitForRecycled())
        let second = await harness.nimSession(1)
        await second.emit(.error(code: "inference_timeout", message: "slow"))
        #expect(await client.waitForDegraded(.engineError, recovering: false))
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.nim.sessions.count == 2)
        #expect(client.phases.last == .degraded)
        #expect(!client.isClosed)
        await client.close()
    }

    @Test func aLaterFaultGetsItsOwnRecycle() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let first = await harness.nimSession(0)
        await first.emit(.error(code: "inference_error", message: "boom"))
        #expect(await client.waitForRecycled())
        let second = await harness.nimSession(1)
        harness.clock.advance(by: 120)
        await second.emit(.error(code: "inference_error", message: "boom again"))
        #expect(await eventually { client.count { $0 == .recycled } == 2 })
        #expect(await eventually { harness.nim.sessions.count == 3 })
        await client.close()
    }

    @Test func nimSocketClosingIsAFault() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        nim.close()
        #expect(await client.waitForDegraded(.engineError, recovering: true))
        #expect(await client.waitForRecycled())
        await client.close()
    }

    @Test func silentNIMWhileAReplyIsDueIsAFault() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        try await Task.sleep(for: .milliseconds(50))
        let fired = await harness.advance(until: { client.messages.contains(.degraded(.engineError, recovering: true)) }, step: 3)
        #expect(fired)
        #expect(await client.waitForRecycled())
        await client.close()
    }

    @Test func aQuietNIMWhenNothingIsOwedIsFine() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        _ = await harness.nimSession()
        for _ in 0..<5 {
            harness.clock.advance(by: 10)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.count { if case .degraded = $0 { true } else { false } } == 0)
        await client.close()
    }

    @Test func unreachableNIMAtConnectIsEngineDown() async throws {
        let harness = await GatewayHarness.start(nimURL: "ws://127.0.0.1:1/v1/realtime")
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.hello()
        #expect(await client.waitForError("engineDown"))
        #expect(await client.waitClosed())
        #expect(!client.messages.contains { if case .ready = $0 { true } else { false } })
        #expect(await eventually { harness.gateway.calls == 0 })
    }

    @Test func silentClientIsClosedAfterFifteenSeconds() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        _ = await harness.nimSession()
        harness.clock.advance(by: 14)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!client.isClosed)
        let closed = await harness.advance(until: { client.isClosed }, step: 2)
        #expect(closed)
        #expect(await eventually { harness.gateway.calls == 0 })
    }

    @Test func anyClientFrameKeepsTheCallAlive() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        _ = await harness.nimSession()
        for _ in 0..<5 {
            client.channel.send(binary: Data(count: 3_840))
            try await Task.sleep(for: .milliseconds(30))
            harness.clock.advance(by: 10)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(!client.isClosed)
        await client.close()
    }
}
