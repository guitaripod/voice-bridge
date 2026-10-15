import Foundation
import Testing
import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct LateTranscriptTests {
    let relaxed: GatewayLimits = {
        var limits = GatewayLimits.contract
        limits.clientSilenceSeconds = 100_000
        limits.helloTimeoutSeconds = 100_000
        return limits
    }()

    @Test func toolBeforeTranscriptAnswersSentAndDispatchesWhenTheTranscriptCompletes() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personStops(item: "a")
        let output = await nim.callTool("send_to_agent")
        #expect(output == "Sent.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.dispatches.isEmpty)
        await nim.transcriptArrives("fix the failing test", item: "a")
        #expect(await eventually { client.dispatches.count == 1 })
        #expect(client.dispatches.first?.text == "fix the failing test")
        await client.close()
    }

    @Test func transcriptBeforeToolDispatchesAtOnce() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("fix the failing test", item: "a")
        let output = await nim.callTool("send_to_agent")
        #expect(output == "Sent.")
        #expect(await eventually { client.dispatches.count == 1 })
        await nim.transcriptArrives("and then something else", item: "b")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.dispatches.count == 1)
        await client.close()
    }

    @Test func pendingWordsAreJoinedWithTheLateTranscript() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("rename the helper", item: "a")
        await nim.personStops(item: "b")
        let output = await nim.callTool("send_to_agent")
        #expect(output == "Sent.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.dispatches.isEmpty)
        await nim.transcriptArrives("and run the tests", item: "b")
        #expect(await eventually { client.dispatches.count == 1 })
        #expect(client.dispatches.first?.text == "rename the helper and run the tests")
        await client.close()
    }

    @Test func noTranscriptAtAllDropsTheIntentAfterThreeSeconds() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personStops(item: "a")
        let output = await nim.callTool("send_to_agent")
        #expect(output == "Sent.")
        for _ in 0..<10 {
            harness.clock.advance(by: 0.5)
            try await Task.sleep(for: .milliseconds(20))
        }
        await nim.transcriptArrives("far too late to matter", item: "a")
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.dispatches.isEmpty)
        let again = await nim.callTool("send_to_agent", callID: "call-2")
        #expect(again == "Sent.")
        #expect(await eventually { client.dispatches.count == 1 })
        await client.close()
    }

    @Test func twoUtterancesInARowEachGetTheirOwnDispatch() async throws {
        let harness = await GatewayHarness.start(limits: relaxed)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personStops(item: "a")
        _ = await nim.callTool("send_to_agent", callID: "c1")
        await nim.transcriptArrives("first request here", item: "a")
        #expect(await eventually { client.dispatches.count == 1 })
        await nim.personStops(item: "b")
        _ = await nim.callTool("send_to_agent", callID: "c2")
        await nim.transcriptArrives("second request there", item: "b")
        #expect(await eventually { client.dispatches.count == 2 })
        #expect(client.dispatches.map(\.text) == ["first request here", "second request there"])
        await client.close()
    }
}

@Suite(.serialized)
struct DispatchModeTests {
    @Test func configReadsTheMode() {
        #expect(GatewayConfig(environment: [:]).dispatch == .tool)
        #expect(GatewayConfig(environment: ["VOICE_DISPATCH": "transcripts"]).dispatch == .transcripts)
        #expect(GatewayConfig(environment: ["VOICE_DISPATCH": "TOOL"]).dispatch == .tool)
        #expect(GatewayConfig(environment: ["VOICE_DISPATCH": "nonsense"]).dispatch == .tool)
    }

    @Test func healthDetailNamesTheMode() async throws {
        for mode in [DispatchMode.tool, .transcripts] {
            let harness = await GatewayHarness.start(dispatch: mode)
            let health = await harness.gateway.health()
            #expect(health.detail?.contains("Dispatch: \(mode.rawValue).") == true)
            await harness.stop()
        }
    }

    @Test func transcriptsModeDispatchesEveryFinalTranscriptOfThreeWords() async throws {
        let harness = await GatewayHarness.start(dispatch: .transcripts)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("fix the failing test", item: "a")
        #expect(await eventually { client.dispatches.count == 1 })
        #expect(client.dispatches.first?.text == "fix the failing test")
        await nim.personSays("  okay thanks  ", item: "b")
        await nim.personSays("now run all the tests", item: "c")
        #expect(await eventually { client.dispatches.count == 2 })
        #expect(client.dispatches.map(\.text) == ["fix the failing test", "now run all the tests"])
        #expect(client.messages.contains(.user(id: "b", text: "okay thanks", final: true)))
        await client.close()
    }

    @Test func sendToAgentOnlyAnswersInTranscriptsMode() async throws {
        let harness = await GatewayHarness.start(dispatch: .transcripts)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personStops(item: "a")
        let early = await nim.callTool("send_to_agent", callID: "c1")
        #expect(early == "Sent.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.dispatches.isEmpty)
        await nim.transcriptArrives("please fix the build", item: "a")
        #expect(await eventually { client.dispatches.count == 1 })
        let again = await nim.callTool("send_to_agent", callID: "c2")
        #expect(again == "Already sent.")
        #expect(client.dispatches.count == 1)
        await nim.emit(.speechStarted)
        let fresh = await nim.callTool("send_to_agent", callID: "c3")
        #expect(fresh == "Sent.")
        #expect(client.dispatches.count == 1)
        await client.close()
    }

    @Test func toolModeStaysTheDefault() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("fix the failing test", item: "a")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.dispatches.isEmpty)
        let output = await nim.callTool("send_to_agent")
        #expect(output == "Sent.")
        #expect(await eventually { client.dispatches.count == 1 })
        await client.close()
    }

    @Test func refusedTranscriptsAreNotRequeuedInTranscriptsMode() async throws {
        let harness = await GatewayHarness.start(dispatch: .transcripts)
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("fix the failing test", item: "a")
        #expect(await eventually { client.dispatches.count == 1 })
        client.send(.refused(id: client.dispatches[0].id, reason: "busy"))
        try await Task.sleep(for: .milliseconds(100))
        await nim.personSays("run all the tests", item: "b")
        #expect(await eventually { client.dispatches.count == 2 })
        #expect(client.dispatches.last?.text == "run all the tests")
        await client.close()
    }
}
