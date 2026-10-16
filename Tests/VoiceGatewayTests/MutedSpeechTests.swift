import Foundation
import Testing
@testable import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct MutedSpeechTests {
    let relaxed: GatewayLimits = {
        var limits = GatewayLimits.contract
        limits.clientSilenceSeconds = 100_000
        limits.helloTimeoutSeconds = 100_000
        return limits
    }()

    func muted(dispatch: DispatchMode = .transcripts) async -> GatewayHarness {
        await GatewayHarness.start(limits: relaxed, dispatch: dispatch, speech: .muted)
    }

    func sawNothingFromTheModel(_ client: TestClient) -> Bool {
        let said = client.messages.contains { if case .say = $0 { true } else { false } }
        return client.audio.isEmpty && !said && !client.phases.contains(.speaking)
    }

    @Test func theDefaultsAreMutedAndTranscripts() {
        let config = GatewayConfig(environment: [:])
        #expect(config.speech == .muted)
        #expect(config.dispatch == .transcripts)
        #expect(config.effectiveDispatch == .transcripts)
        #expect(GatewayConfig().speech == .muted && GatewayConfig().dispatch == .transcripts)
    }

    @Test func theEnvironmentChoosesTheSpeechAndAMutedModelAlwaysDispatchesTranscripts() {
        #expect(GatewayConfig(environment: ["VOICE_SPEECH": "model"]).speech == .model)
        #expect(GatewayConfig(environment: ["VOICE_SPEECH": "MUTED"]).speech == .muted)
        #expect(GatewayConfig(environment: ["VOICE_SPEECH": "loud"]).speech == .muted)
        let toolWithSpeech = GatewayConfig(environment: ["VOICE_SPEECH": "model", "VOICE_DISPATCH": "tool"])
        #expect(toolWithSpeech.effectiveDispatch == .tool)
        let toolWithoutSpeech = GatewayConfig(environment: ["VOICE_DISPATCH": "tool"])
        #expect(toolWithoutSpeech.dispatch == .tool && toolWithoutSpeech.effectiveDispatch == .transcripts)
    }

    @Test func noToolsAreRegisteredAndTheInstructionIsTheMinimalAsciiOne() async throws {
        let harness = await muted()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let update = try #require(await harness.nimSession().message("session.update"))
        let session = try #require(update.json["session"])
        #expect(session["tools"] == nil)
        #expect(session["instructions"]?.string == VoiceTools.mutedPrompt)
        #expect(VoiceTools.mutedPrompt.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F })
        #expect(VoiceTools.mutedPrompt.count < VoiceTools.promptLimit)
        #expect(VoiceTools.mutedPrompt.count < VoiceTools.systemPrompt.count)
        await client.close()
    }

    @Test func aSpeakingModelStillRegistersTheThreeTools() async throws {
        let harness = await GatewayHarness.start(limits: relaxed, speech: .model)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let update = try #require(await harness.nimSession().message("session.update"))
        guard case .array(let tools)? = update.json["session"]?["tools"] else {
            Issue.record("no tools")
            return
        }
        #expect(tools.count == 3)
        #expect(update.json["session"]?["instructions"]?.string == VoiceTools.systemPrompt)
        await client.close()
    }

    @Test func modelAudioAndWordsNeverReachTheClientAndThePhaseNeverSpeaks() async throws {
        let harness = await muted()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        await nim.speak(seconds: 1)
        await nim.emit(.transcriptDelta("I can run those tests for you."))
        await nim.emit(.transcriptDone("I can run those tests for you."))
        await nim.emit(.responseDone(status: "completed"))
        await nim.personSays("fix the failing test", item: "a")
        #expect(await eventually { client.dispatches.count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(sawNothingFromTheModel(client))
        #expect(client.phases.allSatisfy { [.listening, .hearing].contains($0) })
        #expect(client.phases.contains(.hearing))
        await client.close()
    }

    @Test func aModelThatRamblesIntoTheVoidIsNotARunaway() async throws {
        let harness = await muted()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        for _ in 0..<10 { await nim.speak(seconds: 4) }
        await nim.emit(.responseDone(status: "completed"))
        await nim.emit(.error(code: "barrier", message: "after the audio"))
        #expect(await client.waitForDegraded(.engineError, recovering: true))
        #expect(!client.messages.contains(.degraded(.runaway, recovering: true)))
        #expect(!client.messages.contains(.degraded(.runaway, recovering: false)))
        await client.close()
    }

    @Test func audioLongAfterTheResponseIsDoneIsNotARunawayEither() async throws {
        let harness = await muted()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        await nim.emit(.responseDone(status: "completed"))
        harness.clock.advance(by: 5)
        await nim.speak(seconds: 0.08)
        await nim.emit(.error(code: "barrier", message: "after the audio"))
        #expect(await client.waitForDegraded(.engineError, recovering: true))
        #expect(!client.messages.contains(.degraded(.runaway, recovering: true)))
        await client.close()
    }

    @Test func aLoopingTranscriptIsIgnored() async throws {
        let harness = await muted()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        for _ in 0..<12 { await nim.emit(.transcriptDelta("I can help with that. ")) }
        await nim.emit(.error(code: "barrier", message: "after the words"))
        #expect(await client.waitForDegraded(.engineError, recovering: true))
        #expect(!client.messages.contains(.degraded(.loop, recovering: true)))
        #expect(sawNothingFromTheModel(client))
        await client.close()
    }

    @Test func aNIMErrorStillDegradesAndRecyclesTheCall() async throws {
        let harness = await muted()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.error(code: "boom", message: "engine"))
        #expect(await client.waitForDegraded(.engineError, recovering: true))
        #expect(await client.waitForRecycled())
        let second = await harness.nimSession(1)
        let update = try #require(await second.message("session.update"))
        #expect(update.json["session"]?["tools"] == nil)
        #expect(update.json["session"]?["instructions"]?.string == VoiceTools.mutedPrompt)
        await client.close()
    }

    @Test func aSilentNIMWhileAReplyIsDueStillApplies() async throws {
        let harness = await muted()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        try await Task.sleep(for: .milliseconds(50))
        let fired = await harness.advance(until: { client.messages.contains(.degraded(.engineError, recovering: true)) }, step: 3)
        #expect(fired)
        await client.close()
    }

    @Test func aToolCallThatSomehowArrivesIsAnsweredAsUnknownAndDispatchesNothing() async throws {
        let harness = await muted()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("fix the failing test", item: "a")
        #expect(await eventually { client.dispatches.count == 1 })
        let output = await nim.callTool("stop_agent")
        #expect(output == "That tool does not exist.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!client.messages.contains(.stop))
        #expect(client.dispatches.count == 1)
        await client.close()
    }

    @Test func everyFinalTranscriptOfThreeWordsIsDispatchedAndShorterOnesAreNot() async throws {
        let harness = await muted()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("okay thanks", item: "a")
        await nim.personSays("one two three", item: "b")
        await nim.personSays("  add a dark mode  ", item: "c")
        await nim.personSays("hmm", item: "d")
        #expect(await eventually { client.dispatches.count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.dispatches.map(\.text) == ["one two three", "add a dark mode"])
        #expect(client.messages.contains(.user(id: "a", text: "okay thanks", final: true)))
        await client.close()
    }

    @Test func toolDispatchConfiguredWithAMutedModelStillDispatchesTranscripts() async throws {
        let harness = await muted(dispatch: .tool)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("fix the failing test", item: "a")
        #expect(await eventually { client.dispatches.count == 1 })
        await client.close()
    }

    @Test func healthDetailNamesBothSettings() async {
        for (dispatch, speech, expected) in [
            (DispatchMode.transcripts, SpeechMode.muted, "Dispatch: transcripts. Speech: muted."),
            (.tool, .muted, "Dispatch: transcripts. Speech: muted."),
            (.tool, .model, "Dispatch: tool. Speech: model."),
            (.transcripts, .model, "Dispatch: transcripts. Speech: model."),
        ] {
            let harness = await GatewayHarness.start(dispatch: dispatch, speech: speech)
            let health = await harness.gateway.health()
            #expect(health.detail?.hasSuffix(expected) == true, "\(health.detail ?? "")")
            await harness.stop()
        }
    }

    @Test func speakingModeStillForwardsAudioWordsAndTheSpeakingPhase() async throws {
        let harness = await GatewayHarness.start(limits: relaxed, speech: .model)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.emit(.responseCreated)
        await nim.speak(seconds: 0.5)
        await nim.emit(.transcriptDone("Okay."))
        #expect(await eventually { !client.audio.isEmpty })
        #expect(await eventually { client.messages.contains(.say(text: "Okay.", final: true)) })
        #expect(client.phases.contains(.speaking))
        await client.close()
    }

    @Test func sessionUpdateOmitsToolsWhenThereAreNone() throws {
        let json = try #require(JSONValue.parse(NIMMessages.sessionUpdate(instructions: "hi", tools: [])))
        #expect(json["session"]?["tools"] == nil)
        #expect(json["session"]?["instructions"]?.string == "hi")
        #expect(json["session"]?["audio"]?["input"]?["format"]?.string == "pcm16")
    }
}
