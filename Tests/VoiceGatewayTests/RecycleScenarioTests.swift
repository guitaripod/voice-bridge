import Foundation
import Testing
import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct RecycleScenarioTests {
    let relaxed: GatewayLimits = {
        var limits = GatewayLimits.contract
        limits.clientSilenceSeconds = 100_000
        limits.helloTimeoutSeconds = 100_000
        return limits
    }()

    @Test func ninetySecondsOfAudioRecyclesAtAQuietMoment() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let first = await harness.nimSession(0)
        client.sendAudio(seconds: 91, frameBytes: VoiceWire.maxChunkBytes)
        #expect(await first.waitForAudio(bytes: PCM.bytes(seconds: 91)))
        #expect(await first.message("session.close") == nil)
        let recycled = await harness.advance(until: { client.messages.contains(.recycled) })
        #expect(recycled)
        let second = await harness.nimSession(1)
        #expect(await first.message("session.close") != nil)
        #expect(second.received.first?.type == "session.update")
        #expect(client.phases.last == .listening)
        await client.close()
    }

    @Test func fourTurnsRecycleOnceTheModelIsDone() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        for turn in 0..<4 {
            await nim.personSays("turn \(turn)")
        }
        await nim.emit(.responseCreated)
        try await Task.sleep(for: .milliseconds(100))
        harness.clock.advance(by: 5)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!client.messages.contains(.recycled))
        await nim.emit(.responseDone(status: "completed"))
        let recycled = await harness.advance(until: { client.messages.contains(.recycled) })
        #expect(recycled)
        #expect(await eventually { harness.nim.sessions.count == 2 })
        await client.close()
    }

    @Test func audioDuringTheSwapIsBufferedUpToTwoSecondsAndReplayed() async throws {
        let harness = await GatewayHarness.start(options: .init(upgradeDelay: { $0 == 1 ? 0.6 : 0 }), limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let first = await harness.nimSession(0)
        client.sendAudio(seconds: 91, frameBytes: VoiceWire.maxChunkBytes)
        #expect(await first.waitForAudio(bytes: PCM.bytes(seconds: 91)))
        let swapping = await harness.advance(until: { harness.nim.attempts == 2 })
        #expect(swapping)
        client.sendAudio(seconds: 3)
        #expect(await client.waitForRecycled())
        let second = await harness.nimSession(1)
        #expect(await second.waitForAudio(bytes: PCM.bytes(seconds: 2)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(second.audioBytesReceived == PCM.bytes(seconds: 2))
        let types = second.received.map(\.type)
        #expect(types.first == "session.update")
        #expect(types.dropFirst().allSatisfy { $0 == "input_audio_buffer.append" })
        await client.close()
    }

    @Test func callContinuesAfterTheSwap() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let first = await harness.nimSession(0)
        client.sendAudio(seconds: 91, frameBytes: VoiceWire.maxChunkBytes)
        #expect(await first.waitForAudio(bytes: PCM.bytes(seconds: 91)))
        let recycled = await harness.advance(until: { client.messages.contains(.recycled) })
        #expect(recycled)
        let second = await harness.nimSession(1)
        await second.personSays("keep going")
        let output = await second.callTool("send_to_agent")
        #expect(output == "Sent.")
        #expect(client.dispatches.last?.text == "keep going")
        await client.close()
    }

    @Test func pendingTranscriptsSurviveARecycle() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let first = await harness.nimSession(0)
        await first.personSays("remember this")
        client.sendAudio(seconds: 91, frameBytes: VoiceWire.maxChunkBytes)
        let recycled = await harness.advance(until: { client.messages.contains(.recycled) })
        #expect(recycled)
        let second = await harness.nimSession(1)
        let output = await second.callTool("send_to_agent")
        #expect(output == "Sent.")
        #expect(client.dispatches.last?.text == "remember this")
        await client.close()
    }

    @Test func failedSwapEndsInEngineDown() async throws {
        let harness = await GatewayHarness.start(options: .init(refuse: { $0 >= 1 }), limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.error(code: "inference_error", message: "boom"))
        #expect(await client.waitForDegraded(.engineError, recovering: true))
        #expect(await client.waitForDegraded(.engineDown, recovering: false))
        #expect(!client.isClosed)
        await client.close()
    }
}
