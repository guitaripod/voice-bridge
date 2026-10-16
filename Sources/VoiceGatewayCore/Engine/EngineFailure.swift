import Foundation

/// Why the voice engine did not come up, as an id the app can put into words and the facts that go with
/// it: for `gpuMemory` the free and wanted memory, and for any of them the last lines of the container's log.
struct EngineFailure: Sendable, Equatable {
    static let gpuMemory = "gpuMemory"
    static let exited = "exited"
    static let notReady = "notReady"
    static let startFailed = "startFailed"

    static let logLines = 60
    static let tailLines = 10

    var id: String
    var reason: String
    var facts: [String: String] = [:]

    static func startFailed(_ reason: String, tail: [String]) -> EngineFailure {
        EngineFailure(id: startFailed, reason: reason, facts: JobFailure.tailFacts(clipped(tail)))
    }

    static func notReady(minutes: Int, log: [String]) -> EngineFailure {
        EngineFailure(
            id: notReady, reason: "the voice engine was not ready after \(minutes) minutes",
            facts: JobFailure.tailFacts(clipped(log)))
    }

    /// The container is gone or stopped while it was loading. `log` is what `docker logs` said before the
    /// container was removed; `free` is the GPU's free memory now, used when the log does not give its own.
    static func exited(log: [String], freeMB: Int) -> EngineFailure {
        let tail = JobFailure.tailFacts(clipped(log))
        guard let memory = GPUMemoryMessage.find(in: log) else {
            return EngineFailure(id: exited, reason: "the voice engine container stopped while loading", facts: tail)
        }
        let free = memory.freeMB ?? freeMB
        let need = memory.wantedMB ?? VoiceRequirements.freeVRAMMB
        return EngineFailure(
            id: gpuMemory,
            reason: "the GPU did not have the memory the voice engine asked for (\(free / 1_000) GB free, \(need / 1_000) GB wanted)",
            facts: ["freeMB": "\(free)", "needMB": "\(need)"].merging(tail) { _, new in new })
    }

    static func clipped(_ lines: [String]) -> [String] {
        lines.suffix(tailLines).map { String($0.prefix(300)) }
    }
}

/// vLLM's refusal to start an engine: "Free memory on device (34.67/95.05 GiB) is less than desired GPU
/// memory utilization (0.4, 38.02 GiB)".
enum GPUMemoryMessage {
    static let phrase = "less than desired GPU memory utilization"

    struct Found: Equatable {
        var freeMB: Int?
        var wantedMB: Int?
    }

    static func find(in lines: [String]) -> Found? {
        guard let line = lines.last(where: { $0.contains(phrase) }) else { return nil }
        let pattern = #"Free memory on device \(([0-9.]+)/[0-9.]+ GiB\).*desired GPU memory utilization \([0-9.]+, ([0-9.]+) GiB\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return Found() }
        func mebibytes(_ group: Int) -> Int? {
            Range(match.range(at: group), in: line).flatMap { Double(line[$0]) }.map { Int(($0 * 1_024).rounded()) }
        }
        return Found(freeMB: mebibytes(1), wantedMB: mebibytes(2))
    }
}
