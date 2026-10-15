import Foundation
import VoiceKit

extension CallSession {
    func nimInbound(_ item: NIMInbound, generation current: Int) async {
        guard !finished, !swapping, !terminal, current == generation else { return }
        switch item {
        case .closed(let reason):
            logger.warning("nim socket closed", metadata: ["reason": "\(reason ?? "-")"])
            fault(.engineError)
        case .event(let event):
            lastNIMEvent = clock.now()
            await nimEvent(event)
        }
    }

    private func nimEvent(_ event: NIMEvent) async {
        let now = clock.now()
        switch event {
        case .speechStarted:
            userSpeaking = true
            responding = false
            runaway.userSpoke()
            lastActivity = now
            setPhase(.hearing)
        case .speechStopped:
            userSpeaking = false
            recycle.turnEnded()
            lastActivity = now
            if phase == .hearing { setPhase(.listening) }
        case .userTranscriptDelta(let item, let delta):
            userDelta(item: item, delta: delta)
        case .userTranscriptCompleted(let item, let transcript):
            userCompleted(item: item, transcript: transcript)
        case .responseCreated:
            responding = true
            toolPending = false
            runaway.responseStarted()
            loop.reset()
            lastActivity = now
        case .audioDelta(let pcm):
            await modelAudio(pcm, at: now)
        case .transcriptDelta(let delta):
            if loop.feed(delta) {
                fault(.loop)
            } else {
                outbox.send(.say(text: loop.text, final: false))
            }
        case .transcriptDone(let transcript):
            outbox.send(.say(text: transcript, final: true))
            loop.reset()
        case .responseDone:
            responding = false
            runaway.responseDone(at: now)
            lastActivity = now
            if !userSpeaking { setPhase(.listening) }
        case .functionCall(let callID, let name, _):
            answerTool(callID: callID, name: name)
        case .error(let code, let message):
            logger.warning("nim error", metadata: ["code": "\(code)", "message": "\(message)"])
            fault(.engineError)
        case .sessionEnd:
            fault(.engineError)
        case .sessionCreated, .sessionUpdated, .audioDone, .other:
            break
        }
    }

    private func userDelta(item: String, delta: String) {
        var accumulator = userTexts[item] ?? TextAccumulator()
        accumulator.append(delta)
        userTexts[item] = accumulator
        outbox.send(.user(id: userID(item), text: accumulator.text, final: false))
    }

    private func userCompleted(item: String, transcript: String) {
        userTexts.removeValue(forKey: item)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        outbox.send(.user(id: userID(item), text: text, final: true))
        buffer.append(text)
    }

    private func userID(_ item: String) -> String {
        guard item.isEmpty else { return item }
        userCounter += 1
        return "u\(userCounter)"
    }

    private func modelAudio(_ pcm: Data, at now: Double) async {
        lastActivity = now
        let seconds = PCM.seconds(bytes: pcm.count)
        recycle.addAudio(seconds: seconds)
        if runaway.audio(seconds: seconds, at: now) {
            fault(.runaway)
            return
        }
        guard !userSpeaking else { return }
        let aligned = audioCarry + pcm
        let usable = aligned.count & ~1
        audioCarry = Data(aligned.suffix(aligned.count - usable))
        guard usable > 0 else { return }
        outbox.sendAudio(Data(aligned.prefix(usable)))
        setPhase(.speaking)
    }

    private func answerTool(callID: String, name: String) {
        toolPending = true
        lastActivity = clock.now()
        let outcome = ToolRouter.run(name: name, agent: agent, buffer: &buffer)
        for effect in outcome.effects {
            switch effect {
            case .dispatch(let id, let text):
                dispatched[id] = text
                outbox.send(.dispatch(id: id, text: text))
            case .stop:
                outbox.send(.stop)
            }
        }
        nim?.answer(callID: callID, output: VoiceText.ascii(outcome.output))
    }
}
