import Synchronization

/// Whether the client's socket is still there, for the stretch of a call before its frames are read.
final class ClientPresence: Sendable {
    private let gone = Mutex(false)

    var isGone: Bool { gone.withLock { $0 } }

    func leave() {
        gone.withLock { $0 = true }
    }
}
