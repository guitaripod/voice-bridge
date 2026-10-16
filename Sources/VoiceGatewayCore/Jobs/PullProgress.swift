import Foundation

/// Docker prints no totals when its output is not a terminal, only a status per layer. Progress is the
/// share of layers that are finished: coarse, because layers differ in size, but it only ever moves forward.
struct PullProgress: Sendable, Equatable {
    private(set) var layers: Set<String> = []
    private(set) var finished: Set<String> = []

    var fraction: Double? {
        guard !layers.isEmpty else { return nil }
        return min(0.99, Double(finished.count) / Double(layers.count))
    }

    mutating func feed(_ line: String) {
        guard let colon = line.firstIndex(of: ":") else { return }
        let id = String(line[..<colon])
        guard id.count >= 8, id.count <= 64, id.allSatisfy(\.isHexDigit) else { return }
        let status = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        layers.insert(id)
        if status.hasPrefix("Pull complete") || status.hasPrefix("Already exists") { finished.insert(id) }
    }
}
