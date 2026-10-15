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
    case awaitTranscript
}

struct ToolOutcome: Sendable, Equatable {
    var output: String
    var effects: [ToolEffect] = []
}

/// Answers the model's tool calls from state the gateway already holds. Nothing here waits.
enum ToolRouter {
    static let sent = "Sent."
    static let nothingToSend = "Nothing to send."
    static let alreadySent = "Already sent."
    static let stopped = "Stopped."
    static let idle = "The agent is idle."
    static let unknown = "That tool does not exist."

    /// `transcriptPending`: a speech turn has ended whose transcript has not arrived yet.
    /// `turnDispatched`: transcripts mode already sent the current turn.
    static func run(
        name: String, agent: AgentCache, buffer: inout DispatchBuffer, mode: DispatchMode = .tool,
        transcriptPending: Bool = false, turnDispatched: Bool = false, makeID: () -> String = { UUID().uuidString }
    ) -> ToolOutcome {
        switch name {
        case VoiceTools.sendToAgent:
            if mode == .transcripts { return ToolOutcome(output: turnDispatched ? alreadySent : sent) }
            if transcriptPending { return ToolOutcome(output: sent, effects: [.awaitTranscript]) }
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
