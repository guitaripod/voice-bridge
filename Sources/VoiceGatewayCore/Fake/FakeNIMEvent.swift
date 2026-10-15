import Foundation

/// What a scripted fake NIM can say. Each case renders to the JSON the real server is documented
/// to send.
public enum FakeNIMEvent: Sendable {
    case sessionCreated
    case sessionUpdated
    case speechStarted
    case speechStopped
    case responseCreated
    case audio(Data)
    case audioDone
    case transcriptDelta(String)
    case transcriptDone(String)
    case responseDone(status: String)
    case functionCall(callID: String, name: String, arguments: String)
    case userDelta(itemID: String, delta: String)
    case userCompleted(itemID: String, transcript: String)
    case error(code: String, message: String)
    case sessionEnd
    case raw(String)

    public var json: String {
        func make(_ type: String, _ fields: [String: JSONValue] = [:]) -> String {
            var object = fields
            object["type"] = .string(type)
            object["event_id"] = .string(UUID().uuidString)
            return JSONValue.object(object).serialized()
        }
        switch self {
        case .sessionCreated: return make("session.created")
        case .sessionUpdated: return make("session.updated")
        case .speechStarted: return make("input_audio_buffer.speech_started")
        case .speechStopped: return make("input_audio_buffer.speech_stopped")
        case .responseCreated: return make("response.created")
        case .audio(let pcm): return make("response.output_audio.delta", ["delta": .string(pcm.base64EncodedString())])
        case .audioDone: return make("response.output_audio.done")
        case .transcriptDelta(let delta): return make("response.output_audio_transcript.delta", ["delta": .string(delta)])
        case .transcriptDone(let text): return make("response.output_audio_transcript.done", ["transcript": .string(text)])
        case .responseDone(let status):
            return make("response.done", ["response": .object(["status": .string(status)])])
        case .functionCall(let callID, let name, let arguments):
            return make(
                "response.function_call_arguments.done",
                ["call_id": .string(callID), "name": .string(name), "arguments": .string(arguments)])
        case .userDelta(let item, let delta):
            return make(
                "conversation.item.input_audio_transcription.delta",
                ["item_id": .string(item), "delta": .string(delta)])
        case .userCompleted(let item, let transcript):
            return make(
                "conversation.item.input_audio_transcription.completed",
                ["item_id": .string(item), "transcript": .string(transcript)])
        case .error(let code, let message):
            return make("error", ["error": .object(["code": .string(code), "message": .string(message)])])
        case .sessionEnd: return make("session.end")
        case .raw(let text): return text
        }
    }
}

/// A message the gateway or probe sent to the fake.
public struct FakeNIMReceived: Sendable {
    public let type: String
    public let json: JSONValue

    init(text: String) {
        json = JSONValue.parse(text) ?? .null
        type = json["type"]?.string ?? ""
    }

    public var audio: Data? {
        json["audio"]?.string.flatMap { Data(base64Encoded: $0) }
    }

    public var item: JSONValue? { json["item"] }
}
