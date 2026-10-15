import Foundation
import VoiceKit

/// The script behind `voice-probe fake-nim`: it hears speech as loud audio, waits for a short
/// silence, then runs a whole turn the way the real model is expected to (transcript, a tool call,
/// a spoken reply). Talking over the reply cuts it off.
public enum FakeNIMDemo {
    public static let script: FakeNIMScript = { session in
        await DemoDirector(session: session).run()
    }

    static let phrases = [
        "please fix the failing parser test", "add a retry to the upload code", "how is it going",
        "stop what you are doing", "rename the helper and run the tests",
    ]
}

private actor DemoDirector {
    private let session: FakeNIMSession
    private var heard = false
    private var loudMs = 0
    private var quietMs = 0
    private var turn = 0
    private var reply: Task<Void, Never>?

    init(session: FakeNIMSession) {
        self.session = session
    }

    func run() async {
        for await message in session.messages where message.type == "input_audio_buffer.append" {
            guard let pcm = message.audio else { continue }
            await hear(pcm)
        }
        reply?.cancel()
    }

    private func hear(_ pcm: Data) async {
        let ms = pcm.count * 1000 / PCM.bytesPerSecond
        if Tone.rms(pcm) > 500 {
            quietMs = 0
            loudMs += ms
            if !heard, loudMs >= 160 {
                heard = true
                if reply != nil {
                    reply?.cancel()
                    reply = nil
                    await session.emit(.responseDone(status: "cancelled"))
                }
                await session.emit(.speechStarted)
            }
        } else if heard {
            quietMs += ms
            if quietMs >= 480 {
                heard = false
                loudMs = 0
                await session.emit(.speechStopped)
                startReply()
            }
        } else {
            loudMs = 0
        }
    }

    private func startReply() {
        let phrase = FakeNIMDemo.phrases[turn % FakeNIMDemo.phrases.count]
        let tool = phrase.contains("how is") ? VoiceTools.agentStatus : phrase.contains("stop") ? VoiceTools.stopAgent : VoiceTools.sendToAgent
        turn += 1
        let session = self.session
        let callID = "demo-\(turn)"
        reply = Task {
            await session.emit(.userDelta(itemID: callID, delta: phrase))
            await session.emit(.userCompleted(itemID: callID, transcript: phrase))
            await session.emit(.responseCreated)
            let before = session.received.filter { $0.type == "conversation.item.create" }.count
            await session.emit(.functionCall(callID: callID, name: tool, arguments: "{}"))
            _ = await session.message("conversation.item.create", count: before + 1, timeout: 2)
            await session.emit(.responseCreated)
            await session.emit(.transcriptDelta("Okay, "))
            await session.emit(.transcriptDelta("on it."))
            for _ in 0..<30 {
                if Task.isCancelled { return }
                await session.emit(.audio(Tone.pcm(seconds: 0.08)))
                try? await Task.sleep(for: .milliseconds(80))
            }
            await session.emit(.transcriptDone("Okay, on it."))
            await session.emit(.audioDone)
            await session.emit(.responseDone(status: "completed"))
        }
    }
}
