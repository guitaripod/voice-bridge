/// Spots the model talking in circles: one run of words showing up again and again within the
/// tail of what it said.
struct LoopDetector: Sendable {
    let wordRun: Int
    let repeats: Int
    let windowCharacters: Int
    private var spoken = TextAccumulator()

    init(limits: GatewayLimits) {
        wordRun = limits.loopWordRun
        repeats = limits.loopRepeats
        windowCharacters = limits.loopWindowCharacters
    }

    var text: String { spoken.text }

    mutating func reset() {
        spoken.reset()
    }

    mutating func feed(_ delta: String) -> Bool {
        spoken.append(delta)
        return Self.hasLoop(String(spoken.text.suffix(windowCharacters)), wordRun: wordRun, repeats: repeats)
    }

    static func hasLoop(_ tail: String, wordRun: Int, repeats: Int) -> Bool {
        let words = tail.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        guard words.count >= wordRun else { return false }
        var seen: [[Substring]: Int] = [:]
        for start in 0...(words.count - wordRun) {
            let run = Array(words[start..<(start + wordRun)])
            seen[run, default: 0] += 1
            if seen[run]! >= repeats { return true }
        }
        return false
    }
}
