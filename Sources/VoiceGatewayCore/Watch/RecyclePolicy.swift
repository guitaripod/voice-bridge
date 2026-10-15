/// Counts what the voice session has heard and said, and says when it is time for a fresh one.
struct RecyclePolicy: Sendable {
    let audioSeconds: Double
    let turns: Int
    private(set) var heardSeconds = 0.0
    private(set) var turnCount = 0

    init(limits: GatewayLimits) {
        audioSeconds = limits.recycleAudioSeconds
        turns = limits.recycleTurns
    }

    var due: Bool {
        heardSeconds >= audioSeconds || turnCount >= turns
    }

    mutating func addAudio(seconds: Double) {
        heardSeconds += seconds
    }

    mutating func turnEnded() {
        turnCount += 1
    }

    mutating func reset() {
        heardSeconds = 0
        turnCount = 0
    }
}
