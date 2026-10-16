import Foundation
import Synchronization

/// When the engine was last wanted: calls in progress and the moment the last one ended. The idle stop
/// reads it, the gateway writes it.
final class EngineActivity: Sendable {
    private struct State {
        var calls = 0
        var last: Double
    }

    private let state: Mutex<State>

    init(now: Double) {
        state = Mutex(State(last: now))
    }

    var calls: Int { state.withLock { $0.calls } }
    var last: Double { state.withLock { $0.last } }

    func callBegan(at now: Double) {
        state.withLock {
            $0.calls += 1
            $0.last = now
        }
    }

    func callEnded(at now: Double) {
        state.withLock {
            $0.calls = max(0, $0.calls - 1)
            $0.last = now
        }
    }

    func touch(at now: Double) {
        state.withLock { $0.last = now }
    }
}
