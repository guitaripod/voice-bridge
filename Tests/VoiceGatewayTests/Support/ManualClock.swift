import Synchronization
import VoiceGatewayCore

/// Time that moves only when a test says so; sleepers wake as their deadline passes.
final class ManualClock: VoiceClock {
    private struct Waiter {
        let id: Int
        let deadline: Double
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = 0.0
        var nextID = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    func now() -> Double { state.withLock { $0.now } }

    func sleep(until deadline: Double) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let due = state.withLock { state -> Bool in
                    if deadline <= state.now { return true }
                    state.waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if due { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: Double) {
        let due = state.withLock { state -> [Waiter] in
            state.now += seconds
            let ready = state.waiters.filter { $0.deadline <= state.now }
            state.waiters.removeAll { $0.deadline <= state.now }
            return ready
        }
        due.forEach { $0.continuation.resume() }
    }
}
