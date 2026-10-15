/// The two runaway signs: model audio for too long while the person has not spoken, and model
/// audio that keeps coming well after the response said it was done.
struct RunawayWatch: Sendable {
    let speechSeconds: Double
    let tailSeconds: Double
    private var audioSinceUser = 0.0
    private var doneAt: Double?

    init(limits: GatewayLimits) {
        speechSeconds = limits.runawaySpeechSeconds
        tailSeconds = limits.runawayTailSeconds
    }

    mutating func userSpoke() {
        audioSinceUser = 0
    }

    mutating func responseStarted() {
        doneAt = nil
    }

    mutating func responseDone(at now: Double) {
        doneAt = now
    }

    mutating func reset() {
        audioSinceUser = 0
        doneAt = nil
    }

    mutating func audio(seconds: Double, at now: Double) -> Bool {
        if let doneAt, now - doneAt > tailSeconds { return true }
        audioSinceUser += seconds
        return audioSinceUser > speechSeconds
    }
}
