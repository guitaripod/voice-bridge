import Foundation
import Synchronization
import VoiceGatewayCore

/// A `CommandRunner` that answers from a closure and remembers what it was asked. A command the
/// closure does not know is a program that is not installed.
final class ScriptedRunner: CommandRunner {
    typealias Reply = @Sendable (CommandSpec) -> CommandResult?

    private let reply: Reply
    private let log = Mutex<[CommandSpec]>([])

    init(_ reply: @escaping Reply) {
        self.reply = reply
    }

    var calls: [CommandSpec] { log.withLock { $0 } }

    func called(_ executable: String, _ first: String? = nil) -> [CommandSpec] {
        calls.filter { $0.executable == executable && (first == nil || $0.arguments.first == first) }
    }

    func run(_ spec: CommandSpec) async -> CommandResult {
        log.withLock { $0.append(spec) }
        return reply(spec) ?? .notLaunched("\(spec.executable) is not installed")
    }

    func stream(_ spec: CommandSpec) -> any RunningCommand {
        log.withLock { $0.append(spec) }
        let result = reply(spec) ?? .notLaunched("\(spec.executable) is not installed")
        return ScriptedCommand(result: result)
    }
}

struct ScriptedCommand: RunningCommand {
    let result: CommandResult

    var lines: AsyncStream<String> {
        let text = result.output
        return AsyncStream { continuation in
            for line in text.split(whereSeparator: \.isNewline) { continuation.yield(String(line)) }
            continuation.finish()
        }
    }

    func cancel() {}

    func wait() async -> CommandResult {
        CommandResult(launched: result.launched, status: result.status, output: "", error: result.error)
    }
}

final class FakeNIMProbe: NIMHealthProbe {
    private let state = Mutex(NIMProbeResult.down("not reachable"))

    init(_ result: NIMProbeResult = .down("not reachable")) {
        state.withLock { $0 = result }
    }

    var result: NIMProbeResult {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func check() async -> NIMProbeResult { result }
}
