import Foundation
import VoiceKit

/// The person's final transcripts since the last dispatch.
struct DispatchBuffer: Sendable, Equatable {
    private(set) var pieces: [String] = []

    var isEmpty: Bool { pieces.isEmpty }

    mutating func append(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pieces.append(trimmed) }
    }

    mutating func requeue(_ text: String) {
        pieces.insert(text, at: 0)
    }

    mutating func take() -> String? {
        guard !pieces.isEmpty else { return nil }
        defer { pieces.removeAll() }
        return Self.clip(pieces.joined(separator: " "), to: VoiceWire.dispatchLimit)
    }

    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[..<space])
        }
        return String(head)
    }
}
