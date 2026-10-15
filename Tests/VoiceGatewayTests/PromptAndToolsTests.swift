import Foundation
import Testing
@testable import VoiceGatewayCore

struct PromptAndToolsTests {
    @Test func promptIsShortAndAscii() {
        let prompt = VoiceTools.systemPrompt
        #expect(prompt.count < VoiceTools.promptLimit)
        #expect(prompt.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F })
    }

    @Test func toolsAreThreeAndAscii() {
        #expect(VoiceTools.all.map(\.name) == ["send_to_agent", "agent_status", "stop_agent"])
        for tool in VoiceTools.all {
            for text in [tool.name, tool.description] + tool.ackMessages {
                #expect(text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }, "\(text)")
            }
            #expect(!tool.ackMessages.isEmpty)
            #expect(tool.parameters["type"]?.string == "object")
        }
    }

    @Test func everyByteOfTheSessionUpdateIsAscii() {
        let message = NIMMessages.sessionUpdate(instructions: VoiceTools.systemPrompt, tools: VoiceTools.all)
        #expect(message.utf8.allSatisfy { $0 < 0x80 })
    }

    @Test func sessionUpdateCarriesFormatsInstructionsAndTools() throws {
        let json = try #require(
            JSONValue.parse(NIMMessages.sessionUpdate(instructions: "hi", tools: VoiceTools.all)))
        #expect(json["type"]?.string == "session.update")
        #expect(UUID(uuidString: json["event_id"]?.string ?? "") != nil)
        let session = try #require(json["session"])
        #expect(session["audio"]?["input"]?["format"]?.string == "pcm16")
        #expect(session["audio"]?["output"]?["format"]?.string == "pcm16")
        #expect(session["instructions"]?.string == "hi")
        guard case .array(let tools)? = session["tools"] else { Issue.record("no tools"); return }
        #expect(tools.count == 3)
        #expect(tools[0]["name"]?.string == "send_to_agent")
        guard case .array(let acks)? = tools[0]["ack_messages"] else { Issue.record("no acks"); return }
        #expect(!acks.isEmpty)
    }

    @Test func otherMessagesHaveTheDocumentedShape() throws {
        let audio = try #require(JSONValue.parse(NIMMessages.appendAudio(Data([1, 2, 3, 4]))))
        #expect(audio["type"]?.string == "input_audio_buffer.append")
        #expect(audio["audio"]?.string == Data([1, 2, 3, 4]).base64EncodedString())
        let output = try #require(JSONValue.parse(NIMMessages.functionCallOutput(callID: "c1", output: "Sent.")))
        #expect(output["type"]?.string == "conversation.item.create")
        #expect(output["item"]?["type"]?.string == "function_call_output")
        #expect(output["item"]?["call_id"]?.string == "c1")
        #expect(output["item"]?["output"]?.string == "Sent.")
        #expect(JSONValue.parse(NIMMessages.sessionClose())?["type"]?.string == "session.close")
    }
}
