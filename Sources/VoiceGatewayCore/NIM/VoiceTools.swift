import Foundation

public struct VoiceTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var ackMessages: [String]
    public var parameters: JSONValue
}

/// The persona and the three tools. All of it is ASCII and the prompt stays short, because the
/// model reads it once and forgets it.
public enum VoiceTools {
    public static let sendToAgent = "send_to_agent"
    public static let agentStatus = "agent_status"
    public static let stopAgent = "stop_agent"

    public static let promptLimit = 900

    public static let systemPrompt =
        "You are the voice of a coding agent. The person talks to you instead of typing, and you pass "
        + "their words to the agent. Speak English only. Keep every spoken reply to one or two short "
        + "sentences. Never answer technical questions, never explain code and never guess what the agent "
        + "is doing. When the person has finished stating a task, call send_to_agent once, then say "
        + "briefly that it is sent. When the person asks how it is going, call agent_status and say its "
        + "answer in your own words. When the person asks you to stop or cancel, call stop_agent. If you "
        + "did not understand, ask them to say it again. Do not speak unless the person spoke to you."

    private static let noArguments: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    public static let all: [VoiceTool] = [
        VoiceTool(
            name: sendToAgent,
            description:
                "Send the task the person just described to the coding agent. Call it once, after the person has finished stating the task.",
            ackMessages: ["Sending that now.", "One moment."],
            parameters: noArguments),
        VoiceTool(
            name: agentStatus,
            description: "Get a short account of what the coding agent is doing right now.",
            ackMessages: ["Let me check.", "Checking."],
            parameters: noArguments),
        VoiceTool(
            name: stopAgent,
            description: "Stop whatever the coding agent is doing right now.",
            ackMessages: ["Stopping it.", "On it."],
            parameters: noArguments),
    ]
}
