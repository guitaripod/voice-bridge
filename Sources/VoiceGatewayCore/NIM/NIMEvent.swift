import Foundation

/// What the NIM says, reduced to what the gateway acts on. Anything else, and anything that does
/// not parse, is `.other`: never fatal.
public enum NIMEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    case speechStarted
    case speechStopped
    case responseCreated
    case audioDelta(Data)
    case audioDone
    case transcriptDelta(String)
    case transcriptDone(String)
    case responseDone(status: String?)
    case functionCall(callID: String, name: String, arguments: String)
    case userTranscriptDelta(itemID: String, delta: String)
    case userTranscriptCompleted(itemID: String, transcript: String)
    case error(code: String, message: String)
    case sessionEnd
    case other(String)

    public static func parse(_ text: String) -> NIMEvent {
        guard let json = JSONValue.parse(text), let type = json["type"]?.string else { return .other("unparseable") }
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "input_audio_buffer.speech_started": return .speechStarted
        case "input_audio_buffer.speech_stopped": return .speechStopped
        case "response.created": return .responseCreated
        case "response.output_audio.delta":
            guard let encoded = json["delta"]?.string, let data = Data(base64Encoded: encoded) else {
                return .other(type)
            }
            return .audioDelta(data)
        case "response.output_audio.done": return .audioDone
        case "response.output_audio_transcript.delta":
            return json["delta"]?.string.map(NIMEvent.transcriptDelta) ?? .other(type)
        case "response.output_audio_transcript.done":
            return json["transcript"]?.string.map(NIMEvent.transcriptDone) ?? .other(type)
        case "response.done":
            return .responseDone(status: json["response"]?["status"]?.string)
        case "response.function_call_arguments.done":
            guard let callID = json["call_id"]?.string, let name = json["name"]?.string else { return .other(type) }
            return .functionCall(callID: callID, name: name, arguments: json["arguments"]?.string ?? "{}")
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = json["delta"]?.string else { return .other(type) }
            return .userTranscriptDelta(itemID: json["item_id"]?.string ?? "", delta: delta)
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = json["transcript"]?.string else { return .other(type) }
            return .userTranscriptCompleted(itemID: json["item_id"]?.string ?? "", transcript: transcript)
        case "error":
            return .error(
                code: json["error"]?["code"]?.string ?? "unknown",
                message: json["error"]?["message"]?.string ?? "")
        case "session.end": return .sessionEnd
        default: return .other(type)
        }
    }
}
