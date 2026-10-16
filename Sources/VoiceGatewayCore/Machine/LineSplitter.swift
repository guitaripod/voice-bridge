import Foundation

/// Turns arbitrary chunks of process output into lines. A newline or a carriage return ends a line,
/// terminal escape sequences are dropped and blank lines are skipped.
struct LineSplitter {
    private var pending = Data()

    mutating func feed(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = pending[pending.startIndex..<index]
            pending.removeSubrange(pending.startIndex...index)
            if let text = Self.clean(line) { lines.append(text) }
        }
        return lines
    }

    mutating func finish() -> [String] {
        defer { pending.removeAll() }
        return Self.clean(pending).map { [$0] } ?? []
    }

    static func clean(_ bytes: some DataProtocol) -> String? {
        var text = String(decoding: Data(bytes), as: UTF8.self)
        if text.contains("\u{1B}") {
            text = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
