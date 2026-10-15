import Foundation

/// Monotonic seconds and an absolute-deadline sleep, so every timer in a call can be driven by a test.
public protocol VoiceClock: Sendable {
    func now() -> Double
    func sleep(until deadline: Double) async throws
}

public struct SystemVoiceClock: VoiceClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> Double {
        let elapsed = ContinuousClock.now - origin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    public func sleep(until deadline: Double) async throws {
        let remaining = deadline - now()
        guard remaining > 0 else { return }
        try await Task.sleep(for: .seconds(remaining))
    }
}
