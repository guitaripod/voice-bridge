/// Builds the running text of a transcript from its deltas. A server that sends the whole text so
/// far in every delta, instead of only the new part, replaces rather than doubles.
struct TextAccumulator: Sendable, Equatable {
    private(set) var text = ""

    mutating func append(_ delta: String) {
        if !text.isEmpty, delta.count > text.count, delta.hasPrefix(text) {
            text = delta
        } else {
            text += delta
        }
    }

    mutating func reset() {
        text = ""
    }
}
