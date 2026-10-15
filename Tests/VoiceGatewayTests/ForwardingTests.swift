import Foundation
import Testing
import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct ForwardingTests {
    @Test func microphoneAudioReachesTheNIMInEightyMillisecondChunks() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        client.channel.send(binary: Data(count: VoiceWire.preferredChunkBytes))
        client.channel.send(binary: Data(count: 10_000))
        #expect(await nim.waitForAudio(bytes: VoiceWire.preferredChunkBytes + 10_000))
        let sizes = nim.received.compactMap { $0.audio?.count }
        #expect(sizes == [3_840, 3_840, 3_840, 2_320])
        await client.close()
    }

    @Test func malformedAudioFramesAreDropped() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        client.channel.send(binary: Data(count: 3_841))
        client.channel.send(binary: Data(count: 3_840))
        #expect(await nim.waitForAudio(bytes: 3_840))
        try await Task.sleep(for: .milliseconds(100))
        #expect(nim.audioBytesReceived == 3_840)
        await client.close()
    }

    @Test func modelAudioAndCaptionsReachTheClientAndSpeakingIsReported() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        await nim.emit(.transcriptDelta("Got "))
        await nim.emit(.transcriptDelta("it."))
        await nim.emit(.audio(Data(repeating: 7, count: 3_840)))
        await nim.emit(.transcriptDone("Got it."))
        await nim.emit(.responseDone(status: "completed"))
        #expect(await eventually { client.audio.count == 3_840 })
        #expect(client.audio.allSatisfy { $0 == 7 })
        #expect(client.messages.contains(.say(text: "Got ", final: false)))
        #expect(client.messages.contains(.say(text: "Got it.", final: false)))
        #expect(await client.waitFor { $0 == .say(text: "Got it.", final: true) } != nil)
        #expect(await eventually { client.phases == [.listening, .speaking, .listening] })
        await client.close()
    }

    @Test func speechOverTheModelTellsTheClientToFlushAndDropsLateAudio() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        await nim.emit(.audio(Data(count: 3_840)))
        #expect(await eventually { client.phases.last == .speaking })
        await nim.emit(.speechStarted)
        #expect(await eventually { client.phases.last == .hearing })
        await nim.emit(.audio(Data(count: 3_840)))
        await nim.emit(.speechStopped)
        await nim.emit(.audio(Data(count: 3_840)))
        #expect(await eventually { client.audio.count == 7_680 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.audio.count == 7_680)
        await client.close()
    }

    @Test func unknownAndBrokenNIMEventsAreIgnored() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.raw(#"{"type":"response.content_part.added","part":{}}"#))
        await nim.emit(.raw(#"{"type":"brand.new.event","event_id":"x"}"#))
        await nim.emit(.raw("not json at all"))
        await nim.emit(.raw(#"{"type":"response.output_audio.delta","delta":"@@@"}"#))
        let output = await nim.callTool("agent_status")
        #expect(output == "The agent is idle.")
        #expect(!client.isClosed)
        #expect(client.count { if case .degraded = $0 { true } else { false } } == 0)
        await client.close()
    }

    @Test func byeEndsTheCallAndClosesTheNIMSocket() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        client.send(.bye)
        #expect(await client.waitClosed())
        #expect(await nim.message("session.close") != nil)
        #expect(await eventually { harness.gateway.calls == 0 })
    }
}
