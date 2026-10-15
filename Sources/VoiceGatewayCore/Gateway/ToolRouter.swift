import Foundation
import VoiceKit

struct AgentCache: Sendable, Equatable {
    var busy = false
    var digest = ""
    var turn = 0

    mutating func update(_ state: VoiceClientMessage.AgentState) {
        busy = state.busy
        digest = VoiceText.ascii(state.digest, limit: VoiceWire.digestLimit)
        turn = state.turn
    }
}

enum ToolEffect: Sendable, Equatable {
    case dispatch(id: String, text: String)
    case stop
}

struct ToolOutcome: Sendable, Equatable {
    var output: String
    var effects: [ToolEffect] = []
}

/// Answers the model's tool calls from state the gateway already holds. Nothing here waits.
enum ToolRouter {
    static let sent = "Sent."
    static let nothingToSend = "Nothing to send."
    static let stopped = "Stopped."
    static let idle = "The agent is idle."
    static let unknown = "That tool does not exist."

    static func run(
        name: String, agent: AgentCache, buffer: inout DispatchBuffer, makeID: () -> String = { UUID().uuidString }
    ) -> ToolOutcome {
        switch name {
        case VoiceTools.sendToAgent:
            guard let text = buffer.take() else { return ToolOutcome(output: nothingToSend) }
            return ToolOutcome(output: sent, effects: [.dispatch(id: makeID(), text: text)])
        case VoiceTools.agentStatus:
            let digest = VoiceText.ascii(agent.digest, limit: VoiceWire.digestLimit)
            return ToolOutcome(output: digest.isEmpty ? idle : digest)
        case VoiceTools.stopAgent:
            return ToolOutcome(output: stopped, effects: [.stop])
        default:
            return ToolOutcome(output: unknown)
        }
    }
}
