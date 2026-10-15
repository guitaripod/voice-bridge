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
            turnDispatched = false
            runaway.userSpoke()
            lastActivity = now
            setPhase(.hearing)
        case .speechStopped:
            userSpeaking = false
            recycle.turnEnded()
            stoppedAt.append(now)
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
        if !stoppedAt.isEmpty { stoppedAt.removeFirst() }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            outbox.send(.user(id: userID(item), text: text, final: true))
            switch dispatchMode {
            case .tool: buffer.append(text)
            case .transcripts: dispatchTranscript(text)
            }
        }
        flushIntentIfReady()
    }

    private func dispatchTranscript(_ text: String) {
        guard text.split(whereSeparator: \.isWhitespace).count >= Self.minimumTranscriptWords else {
            logger.debug("transcript too short to dispatch", metadata: ["text": "\(text)"])
            return
        }
        sendDispatch(text)
        turnDispatched = true
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
        let outcome = ToolRouter.run(
            name: name, agent: agent, buffer: &buffer, mode: dispatchMode,
            transcriptPending: transcriptPending(at: lastActivity), turnDispatched: turnDispatched)
        for effect in outcome.effects {
            switch effect {
            case .dispatch(let id, let text):
                recordDispatch(id: id, text: text)
            case .stop:
                outbox.send(.stop)
            case .awaitTranscript:
                dispatchIntentDeadline = lastActivity + limits.transcriptGraceSeconds
            }
        }
        nim?.answer(callID: callID, output: VoiceText.ascii(outcome.output))
    }
}

extension CallSession {
    static let minimumTranscriptWords = 3

    /// A speech turn has ended and its transcript has not come, and has not been given up on.
    func transcriptPending(at now: Double) -> Bool {
        stoppedAt.contains { now - $0 < limits.transcriptGraceSeconds }
    }

    func sendDispatch(_ text: String) {
        recordDispatch(id: UUID().uuidString, text: text)
    }

    func recordDispatch(id: String, text: String) {
        dispatched[id] = text
        outbox.send(.dispatch(id: id, text: text))
    }

    /// The model asked to send before the words arrived: send them the moment the last pending
    /// transcript is in.
    func flushIntentIfReady() {
        guard dispatchIntentDeadline != nil, !transcriptPending(at: clock.now()) else { return }
        settleIntent()
    }

    func expireIntent(at now: Double) {
        stoppedAt.removeAll { now - $0 >= limits.transcriptGraceSeconds }
        guard let deadline = dispatchIntentDeadline, now >= deadline else { return }
        settleIntent()
    }

    private func settleIntent() {
        dispatchIntentDeadline = nil
        if let text = buffer.take() {
            sendDispatch(text)
        } else {
            logger.info("send_to_agent was answered but no transcript arrived in time")
        }
    }
}
