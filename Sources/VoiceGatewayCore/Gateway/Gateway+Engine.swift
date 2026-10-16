import Foundation
import VoiceKit

extension Gateway {
    /// `/health` for an engine this gateway manages. `nil` when somebody else runs the engine: the
    /// NIM's own health answers then.
    func machineHealth(_ machine: MachineServices) async -> VoiceHealth? {
        let (status, managed) = await machine.engine.status()
        guard managed else { return nil }
        let state: VoiceEngineState
        let detail: String
        switch status {
        case .ready: (state, detail) = (.ready, "Ready for a call.")
        case .loading: (state, detail) = (.loading, "The voice engine is loading, this can take five minutes.")
        case .stopped: (state, detail) = (.stopped, "The voice engine is stopped and starts when a call needs it.")
        case .needsSetup: (state, detail) = (.needsSetup, "The voice model is not set up on this machine.")
        case .busy(let free, let need, let holders): (state, detail) = (.busy, Self.busyText(free: free, need: need, holders: holders))
        case .down(let reason): (state, detail) = (.down, "The voice engine is not running: \(reason).")
        }
        return VoiceHealth(gateway: GatewayInfo.version, engine: state, model: GatewayInfo.modelName, calls: 0, detail: describe(detail))
    }

    static func busyText(free: Int, need: Int, holders: [String]) -> String {
        let who = holders.isEmpty ? "another job" : holders.joined(separator: ", ")
        return "The GPU is held by \(who): \(free / 1_000) GB free, the voice model needs \(need / 1_000) GB."
    }

    /// Before a call opens the NIM: start the engine if it is stopped and keep the client informed while
    /// it loads. `false` means the call is over, and the client has been told why.
    func awaitEngine(outbox: ClientOutbox, presence: ClientPresence) async -> Bool {
        guard let machine else { return true }
        switch await machine.engine.requestStart() {
        case .external: return true
        case .status(.ready): return true
        case .status(.loading): return await waitForLoad(machine.engine, outbox: outbox, presence: presence)
        case .status(.needsSetup):
            refuse(.needsSetup, "The voice model is not set up on this machine.", outbox)
        case .status(.busy(let free, let need, let holders)):
            refuse(.busy, Self.busyText(free: free, need: need, holders: holders), outbox)
        case .status(.down(let reason)):
            refuse(.down, "The voice engine is not running: \(reason).", outbox)
        case .status(.stopped):
            refuse(.down, "The voice engine did not start.", outbox)
        }
        return false
    }

    private func refuse(_ state: VoiceEngineState, _ message: String, _ outbox: ClientOutbox) {
        outbox.send(.engine(state, progress: nil))
        outbox.send(.error(code: "engineDown", message: message))
    }

    private func waitForLoad(_ engine: EngineManager, outbox: ClientOutbox, presence: ClientPresence) async -> Bool {
        var nextFrame = clock.now()
        while !Task.isCancelled && !presence.isGone {
            switch await engine.loadSnapshot() {
            case .ready:
                return true
            case .failed(let reason):
                refuse(.down, "The voice engine did not start: \(reason).", outbox)
                return false
            case .idle:
                refuse(.down, "The voice engine stopped while it was loading.", outbox)
                return false
            case .loading(let progress):
                if clock.now() >= nextFrame {
                    outbox.send(.engine(.loading, progress: progress))
                    nextFrame = clock.now() + limits.engineFrameSeconds
                }
            }
            do { try await clock.sleep(until: clock.now() + limits.engineWatchSeconds) } catch { return false }
        }
        return false
    }
}
