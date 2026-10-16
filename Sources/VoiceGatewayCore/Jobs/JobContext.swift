import Foundation
import Synchronization

struct JobProgress: Sendable, Equatable {
    var step: String?
    var fraction: Double?
    var bytesDone: Int64?
    var bytesTotal: Int64?
}

/// What a running job holds on to: a way to report how far it is, and the processes to kill when the
/// person cancels it.
final class JobContext: Sendable {
    private struct State {
        var cancelled = false
        var commands: [Int: any RunningCommand] = [:]
        var next = 0
    }

    let id: String
    private let sink: @Sendable (JobProgress) async -> Void
    private let state = Mutex(State())

    init(id: String, sink: @escaping @Sendable (JobProgress) async -> Void) {
        self.id = id
        self.sink = sink
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func progress(step: String? = nil, fraction: Double? = nil, bytesDone: Int64? = nil, bytesTotal: Int64? = nil) async {
        await sink(JobProgress(step: step, fraction: fraction, bytesDone: bytesDone, bytesTotal: bytesTotal))
    }

    /// Runs a process that streams, killing its group if the job is cancelled while it runs.
    func stream(_ runner: any CommandRunner, _ spec: CommandSpec, onLine: (String) async -> Void) async -> CommandResult {
        let command = runner.stream(spec)
        let key = state.withLock { state -> Int in
            state.next += 1
            state.commands[state.next] = command
            return state.next
        }
        if isCancelled { command.cancel() }
        for await line in command.lines { await onLine(line) }
        let result = await command.wait()
        _ = state.withLock { $0.commands.removeValue(forKey: key) }
        return result
    }

    func cancel() {
        let running = state.withLock { state -> [any RunningCommand] in
            state.cancelled = true
            return Array(state.commands.values)
        }
        running.forEach { $0.cancel() }
    }
}
