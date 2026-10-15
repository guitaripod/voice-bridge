import Foundation
import Testing
import VoiceGatewayCore
import VoiceKit

extension GatewayHarness {
    /// The fake NIM's `index`th connection, once the gateway has opened it and sent its session.update.
    func nimSession(_ index: Int = 0) async -> FakeNIMSession {
        _ = await eventually { nim.sessions.count > index }
        let session = nim.sessions[index]
        _ = await session.message("session.update")
        return session
    }
}

extension FakeNIMSession {
    func personSays(_ text: String, item: String = UUID().uuidString) async {
        await emit(.speechStarted)
        await emit(.userDelta(itemID: item, delta: text))
        await emit(.speechStopped)
        await emit(.userCompleted(itemID: item, transcript: text))
    }

    /// The model asks for a tool and the output the gateway answered with comes back.
    func callTool(_ name: String, callID: String = "call-1") async -> String? {
        let before = received.filter { $0.type == "conversation.item.create" }.count
        await emit(.responseCreated)
        await emit(.functionCall(callID: callID, name: name, arguments: "{}"))
        let answer = await message("conversation.item.create", count: before + 1)
        return answer?.item?["output"]?.string
    }

    func speak(seconds: Double) async {
        let chunk = Data(count: PCM.bytes(seconds: seconds))
        await emit(.audio(chunk))
    }
}

extension TestClient {
    var dispatches: [(id: String, text: String)] {
        messages.compactMap { if case .dispatch(let id, let text) = $0 { (id, text) } else { nil } }
    }

    func waitForDegraded(_ reason: VoiceDegradedReason, recovering: Bool) async -> Bool {
        await waitFor { $0 == .degraded(reason, recovering: recovering) } != nil
    }

    func waitForRecycled() async -> Bool {
        await waitFor { $0 == .recycled } != nil
    }

    func waitForError(_ code: String) async -> Bool {
        await waitFor { if case .error(let c, _) = $0 { c == code } else { false } } != nil
    }
}
