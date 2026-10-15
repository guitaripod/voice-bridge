import Foundation
import VoiceKit

extension CallSession {
    func tick() async {
        guard !finished else { return }
        let now = clock.now()
        if now - lastClientFrame >= limits.clientSilenceSeconds {
            outbox.send(.error(code: "silent", message: "No frame from the client, ending the call."))
            await finish()
            return
        }
        guard !swapping, !terminal else { return }
        expireIntent(at: now)
        if awaitingNIM, now - lastNIMEvent >= limits.engineSilenceSeconds {
            logger.warning("nim silent while a reply was due")
            fault(.engineError)
            return
        }
        if recycle.due, isQuiet(at: now) {
            logger.info("recycling at a quiet moment")
            if !(await swap()) { giveUp(.engineDown) }
        }
    }

    /// A reply is owed by the NIM: it is mid-response, or has just been handed a tool result.
    var awaitingNIM: Bool { responding || toolPending }

    func isQuiet(at now: Double) -> Bool {
        phase == .listening && !userSpeaking && !awaitingNIM && now - lastActivity >= limits.quietSeconds
    }

    /// Mutes the model, tells the client, and swaps in a fresh session. A second fault soon after the
    /// first, or a swap that cannot connect, leaves the call degraded for good. The swap runs in its
    /// own task: the caller is often the very task that reads the old socket, which the swap cancels.
    func fault(_ reason: VoiceDegradedReason) {
        guard !finished, !swapping, !terminal else { return }
        guard faults.canRecycle(at: clock.now()) else {
            giveUp(reason)
            return
        }
        outbox.send(.degraded(reason, recovering: true))
        setPhase(.degraded)
        swapping = true
        recovery = Task { [weak self] in
            guard let self else { return }
            if !(await self.swap()) { await self.giveUp(.engineDown) }
        }
    }

    func giveUp(_ reason: VoiceDegradedReason) {
        guard !finished, !terminal else { return }
        terminal = true
        outbox.send(.degraded(reason, recovering: false))
        setPhase(.degraded)
        pumps.forEach { $0.cancel() }
        guard let session = nim else { return }
        nim = nil
        Task { await session.close() }
    }
}
