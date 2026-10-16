import Foundation

/// How a job ends badly: one of a few ids the app can put into words, with the facts that go with it.
struct JobFailure: Error, Sendable, Equatable {
    static let noDisk = "noDisk"
    static let network = "network"
    static let denied = "denied"
    static let interrupted = "interrupted"
    static let other = "other"

    var id: String
    var facts: [String: String] = [:]

    static func noDisk(needMB: Int, freeMB: Int) -> JobFailure {
        JobFailure(id: noDisk, facts: ["needMB": "\(needMB)", "freeMB": "\(freeMB)"])
    }

    static func other(_ reason: String, tail: [String] = []) -> JobFailure {
        JobFailure(id: other, facts: ["reason": reason].merging(tailFacts(tail)) { _, new in new })
    }

    static func tailFacts(_ lines: [String]) -> [String: String] {
        lines.isEmpty ? [:] : ["tail": lines.joined(separator: "\n")]
    }
}

enum JobResult: Sendable, Equatable {
    case succeeded
    case cancelled
    case failed(JobFailure)
}

/// Reads the last lines a tool printed and says what kind of trouble it was in.
enum FailureClassifier {
    static func classify(_ tail: [String]) -> String {
        let text = tail.joined(separator: " ").lowercased()
        if matches(text, ["no space left", "disk quota", "not enough space", "insufficient space"]) { return JobFailure.noDisk }
        if matches(text, ["denied", "unauthorized", "forbidden", "not authorized", "authentication", "api key", "apikey", "log in", "login"])
            || text.range(of: "\\b(401|403)\\b", options: .regularExpression) != nil
        {
            return JobFailure.denied
        }
        if matches(
            text,
            [
                "network", "resolve", "timeout", "timed out", "connection", "unreachable", "tls", "dial tcp", "no route",
                "temporary failure", "unexpected eof", "bad gateway", "service unavailable",
            ])
        {
            return JobFailure.network
        }
        return JobFailure.other
    }

    private static func matches(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

/// The last few lines of a tool's output, kept while it runs.
struct OutputTail: Sendable {
    private(set) var lines: [String] = []
    let limit: Int

    init(limit: Int = 10) {
        self.limit = limit
    }

    mutating func add(_ line: String) {
        lines.append(String(line.prefix(300)))
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
}
