import Foundation
import Testing
@testable import VoiceGatewayCore

struct NIMEventTests {
    @Test func documentedEventsParse() {
        let pcm = Data([0, 1, 2, 3])
        #expect(NIMEvent.parse(FakeNIMEvent.speechStarted.json) == .speechStarted)
        #expect(NIMEvent.parse(FakeNIMEvent.speechStopped.json) == .speechStopped)
        #expect(NIMEvent.parse(FakeNIMEvent.audio(pcm).json) == .audioDelta(pcm))
        #expect(NIMEvent.parse(FakeNIMEvent.transcriptDelta("hi").json) == .transcriptDelta("hi"))
        #expect(NIMEvent.parse(FakeNIMEvent.transcriptDone("hi there").json) == .transcriptDone("hi there"))
        #expect(NIMEvent.parse(FakeNIMEvent.responseDone(status: "completed").json) == .responseDone(status: "completed"))
        #expect(
            NIMEvent.parse(FakeNIMEvent.functionCall(callID: "c", name: "stop_agent", arguments: "{}").json)
                == .functionCall(callID: "c", name: "stop_agent", arguments: "{}"))
        #expect(
            NIMEvent.parse(FakeNIMEvent.userDelta(itemID: "i", delta: "fix").json)
                == .userTranscriptDelta(itemID: "i", delta: "fix"))
        #expect(
            NIMEvent.parse(FakeNIMEvent.userCompleted(itemID: "i", transcript: "fix it").json)
                == .userTranscriptCompleted(itemID: "i", transcript: "fix it"))
        #expect(NIMEvent.parse(FakeNIMEvent.error(code: "inference_error", message: "x").json) == .error(code: "inference_error", message: "x"))
        #expect(NIMEvent.parse(FakeNIMEvent.sessionEnd.json) == .sessionEnd)
    }

    @Test func unknownAndBrokenEventsAreOther() {
        #expect(NIMEvent.parse(#"{"type":"response.content_part.added"}"#) == .other("response.content_part.added"))
        #expect(NIMEvent.parse(#"{"type":"something.new","x":1}"#) == .other("something.new"))
        #expect(NIMEvent.parse("not json") == .other("unparseable"))
        #expect(NIMEvent.parse(#"{"type":"response.output_audio.delta","delta":"%%%"}"#) == .other("response.output_audio.delta"))
        #expect(NIMEvent.parse(#"{"type":"response.function_call_arguments.done"}"#) == .other("response.function_call_arguments.done"))
    }
}
