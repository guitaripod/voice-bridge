import Foundation
import Testing
import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct DispatchFlowTests {
    @Test func speechBecomesTranscriptsAndSendToAgentDispatchesThemJoined() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()

        await nim.personSays("fix the failing", item: "a")
        await nim.personSays("parser test", item: "b")
        let output = await nim.callTool("send_to_agent")

        #expect(output == "Sent.")
        let dispatch = await client.waitFor { if case .dispatch = $0 { true } else { false } }
        #expect(dispatch != nil)
        #expect(client.dispatches.map(\.text) == ["fix the failing parser test"])
        #expect(client.messages.contains(.user(id: "a", text: "fix the failing", final: false)))
        #expect(client.messages.contains(.user(id: "a", text: "fix the failing", final: true)))
        #expect(client.messages.contains(.user(id: "b", text: "parser test", final: true)))
        let call = nim.received.last { $0.type == "conversation.item.create" }
        #expect(call?.item?["call_id"]?.string == "call-1")
        await client.close()
    }

    @Test func emptyBufferSaysNothingToSend() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        let output = await nim.callTool("send_to_agent")
        #expect(output == "Nothing to send.")
        #expect(client.dispatches.isEmpty)
        await nim.personSays("do the thing")
        _ = await nim.callTool("send_to_agent", callID: "call-2")
        let second = await nim.callTool("send_to_agent", callID: "call-3")
        #expect(second == "Nothing to send.")
        #expect(client.dispatches.count == 1)
        await client.close()
    }

    @Test func agentStatusAnswersTheLastDigestOrIdle() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        let idle = await nim.callTool("agent_status", callID: "s1")
        #expect(idle == "The agent is idle.")

        client.send(.agent(.init(busy: true, digest: "Editing the parser, then running tests.", turn: 4)))
        try await Task.sleep(for: .milliseconds(100))
        let busy = await nim.callTool("agent_status", callID: "s2")
        #expect(busy == "Editing the parser, then running tests.")
        await client.close()
    }

    @Test func digestIsSanitisedBeforeTheModelSeesIt() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        client.send(.agent(.init(busy: true, digest: "R\u{E9}par\u{E9} le fichier \u{1F680} \u{2014} termin\u{E9}", turn: 1)))
        try await Task.sleep(for: .milliseconds(100))
        let output = try #require(await nim.callTool("agent_status"))
        #expect(output == "Repare le fichier termine")
        #expect(output.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F })
        await client.close()
    }

    @Test func stopAgentSendsStop() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        let output = await nim.callTool("stop_agent")
        #expect(output == "Stopped.")
        #expect(await client.waitFor { $0 == .stop } != nil)
        await client.close()
    }

    @Test func refusedDispatchGoesBackIntoTheNextOne() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("first words")
        _ = await nim.callTool("send_to_agent", callID: "c1")
        _ = await client.waitFor { if case .dispatch = $0 { true } else { false } }
        let id = try #require(client.dispatches.first?.id)
        client.send(.refused(id: id, reason: "busy"))
        try await Task.sleep(for: .milliseconds(100))
        await nim.personSays("second words")
        _ = await nim.callTool("send_to_agent", callID: "c2")
        #expect(await eventually { client.dispatches.count == 2 })
        #expect(client.dispatches.last?.text == "first words second words")
        await client.close()
    }

    @Test func toolAnswerComesBackWithinFiftyMilliseconds() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let nim = await harness.nimSession()
        await nim.personSays("warm up the connection")
        _ = await nim.callTool("send_to_agent", callID: "warm")
        let clock = ContinuousClock()
        let before = nim.received.filter { $0.type == "conversation.item.create" }.count
        let start = clock.now
        await nim.emit(.functionCall(callID: "timed", name: "agent_status", arguments: "{}"))
        let answer = await nim.message("conversation.item.create", count: before + 1)
        let elapsed = clock.now - start
        #expect(answer != nil)
        #expect(elapsed < .milliseconds(50), "\(elapsed)")
        await client.close()
    }
}
