import Synchronization

final class Collected: Sendable {
    private let pieces = Mutex<[String]>([])

    func add(_ piece: String) { pieces.withLock { $0.append(piece) } }

    var text: String { pieces.withLock { $0.joined() } }
}
