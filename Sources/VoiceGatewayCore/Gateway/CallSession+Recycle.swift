import Foundation
import VoiceKit

extension CallSession {
    /// Replaces the voice session. The old socket is closed first, because one NIM serves one
    /// session; microphone audio that arrives meanwhile is kept for two seconds and replayed.
    func swap() async -> Bool {
        swapping = true
        replay = ReplayBuffer(seconds: limits.replayBufferSeconds)
        pumps.forEach { $0.cancel() }
        let old = nim
        nim = nil
        await old?.close()
        guard !finished else {
            swapping = false
            return false
        }
        do {
            let fresh = try await NIMSession.open(
                connector: connector, url: nimURL, timeout: limits.nimConnectTimeoutSeconds)
            guard !finished else {
                swapping = false
                await fresh.close()
                return false
            }
            install(fresh)
            startFresh()
            fresh.appendAudio(replay.drain())
            swapping = false
            outbox.send(.recycled)
            setPhase(.listening)
            return true
        } catch {
            swapping = false
            logger.warning("recycle could not connect", metadata: ["error": "\(error)"])
            return false
        }
    }

    private func startFresh() {
        let now = clock.now()
        responding = false
        toolPending = false
        userSpeaking = false
        audioCarry = Data()
        userTexts.removeAll()
        stoppedAt.removeAll()
        dispatchIntentDeadline = nil
        turnDispatched = false
        loop.reset()
        runaway.reset()
        recycle.reset()
        lastNIMEvent = now
        lastActivity = now
    }
}
