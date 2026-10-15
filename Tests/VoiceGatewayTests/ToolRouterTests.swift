import Foundation
import Testing
import VoiceKit
@testable import VoiceGatewayCore

struct ToolRouterTests {
    @Test func sendDispatchesTheJoinedBuffer() {
        var buffer = DispatchBuffer()
        buffer.append("fix the build")
        buffer.append("and push it")
        let outcome = ToolRouter.run(name: "send_to_agent", agent: AgentCache(), buffer: &buffer, makeID: { "id1" })
        #expect(outcome.output == "Sent.")
        #expect(outcome.effects == [.dispatch(id: "id1", text: "fix the build and push it")])
        #expect(buffer.isEmpty)
    }

    @Test func sendWithNothingSaysSo() {
        var buffer = DispatchBuffer()
        let outcome = ToolRouter.run(name: "send_to_agent", agent: AgentCache(), buffer: &buffer)
        #expect(outcome.output == "Nothing to send.")
        #expect(outcome.effects.isEmpty)
    }

    @Test func statusAnswersTheDigestOrIdle() {
        var buffer = DispatchBuffer()
        var agent = AgentCache()
        let answer1 = ToolRouter.run(name: "agent_status", agent: agent, buffer: &buffer).output
        #expect(answer1 == "The agent is idle.")
        agent.update(.init(busy: true, digest: "Editing the parser, then tests.", turn: 3))
        let answer2 = ToolRouter.run(name: "agent_status", agent: agent, buffer: &buffer).output
        #expect(answer2 == "Editing the parser, then tests.")
    }

    @Test func digestIsSanitisedAndLimited() {
        var agent = AgentCache()
        agent.update(.init(busy: true, digest: "Édité le fichier \u{2014} \u{2705} fini " + String(repeating: "x ", count: 400), turn: 1))
        #expect(agent.digest.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F })
        #expect(agent.digest.hasPrefix("Edite le fichier"))
        #expect(agent.digest.count <= VoiceWire.digestLimit)
    }

    @Test func stopAnswersAndSendsStop() {
        var buffer = DispatchBuffer()
        let outcome = ToolRouter.run(name: "stop_agent", agent: AgentCache(), buffer: &buffer)
        #expect(outcome.output == "Stopped.")
        #expect(outcome.effects == [.stop])
    }

    @Test func unknownToolIsAnswered() {
        var buffer = DispatchBuffer()
        let answer3 = ToolRouter.run(name: "launch_missiles", agent: AgentCache(), buffer: &buffer).output.isEmpty
        #expect(!answer3)
    }

    @Test func toolsAnswerInWellUnderFiftyMilliseconds() {
        var buffer = DispatchBuffer()
        buffer.append("fix the test")
        var agent = AgentCache()
        agent.update(.init(busy: true, digest: String(repeating: "working ", count: 60), turn: 2))
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for name in VoiceTools.all.map(\.name) { _ = ToolRouter.run(name: name, agent: agent, buffer: &buffer) }
        }
        #expect(elapsed < .milliseconds(50))
    }
}
