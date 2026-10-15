import Foundation

/// Every message the gateway and the probe send to the NIM is built here and nowhere else.
///
/// Built from NVIDIA's api-reference.md: the envelope (`type`, `event_id`), `session.update` with
/// `session.audio.input/output.format`, `session.instructions` and `session.tools`,
/// `input_audio_buffer.append`, `conversation.item.create` carrying a `function_call_output`, and
/// `session.close`. What the document does not pin down (the wrapper of a tool object, whether
/// `type: "function"` is required, whether a response is started after a tool output) is a guess
/// here, and is verified against the real server at the gate. Change it in this file only.
public enum NIMMessages {
    public static let audioFormat = "pcm16"

    public static func sessionUpdate(instructions: String, tools: [VoiceTool]) -> String {
        envelope(
            "session.update",
            [
                "session": .object([
                    "audio": .object([
                        "input": .object(["format": .string(audioFormat)]),
                        "output": .object(["format": .string(audioFormat)]),
                    ]),
                    "instructions": .string(instructions),
                    "tools": .array(tools.map(toolObject)),
                ])
            ])
    }

    public static func appendAudio(_ pcm: Data) -> String {
        envelope("input_audio_buffer.append", ["audio": .string(pcm.base64EncodedString())])
    }

    public static func functionCallOutput(callID: String, output: String) -> String {
        envelope(
            "conversation.item.create",
            [
                "item": .object([
                    "type": .string("function_call_output"),
                    "call_id": .string(callID),
                    "output": .string(output),
                ])
            ])
    }

    public static func sessionClose() -> String {
        envelope("session.close", [:])
    }

    static func toolObject(_ tool: VoiceTool) -> JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(tool.name),
            "description": .string(tool.description),
            "ack_messages": .array(tool.ackMessages.map(JSONValue.string)),
            "parameters": tool.parameters,
        ])
    }

    private static func envelope(_ type: String, _ fields: [String: JSONValue]) -> String {
        var object = fields
        object["type"] = .string(type)
        object["event_id"] = .string(UUID().uuidString)
        return JSONValue.object(object).serialized()
    }
}
