import Foundation
import Synchronization
@testable import VoiceGatewayCore

/// A stateful stand-in for `docker` and `nvidia-smi`: `docker run` creates the container, `docker stop`
/// removes it, and the GPU's used memory can change between readings. Every command is remembered.
final class FakeHost: CommandRunner {
    struct State: Sendable {
        var machine: FakeMachine
        var calls: [CommandSpec] = []
        var gpuReadings = 0
        var usedAfterFirstReading: Int?
        var runFails: String?
        var stopLeavesContainer = false
        var logs = ""
    }

    private let state: Mutex<State>

    init(_ machine: FakeMachine = FakeMachine()) {
        state = Mutex(State(machine: machine))
    }

    var calls: [CommandSpec] { state.withLock { $0.calls } }
    var machine: FakeMachine {
        get { state.withLock { $0.machine } }
        set { state.withLock { $0.machine = newValue } }
    }

    func configure(_ change: @Sendable (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    func commands(_ executable: String, _ first: String) -> [CommandSpec] {
        calls.filter { $0.executable == executable && $0.arguments.first == first }
    }

    var runs: [CommandSpec] { commands("docker", "run") }
    var stops: [CommandSpec] { commands("docker", "stop") }

    func run(_ spec: CommandSpec) async -> CommandResult {
        state.withLock { state -> CommandResult in
            state.calls.append(spec)
            return answer(spec, &state) ?? .notLaunched("\(spec.executable) is not installed")
        }
    }

    func stream(_ spec: CommandSpec) -> any RunningCommand {
        let result = state.withLock { state -> CommandResult in
            state.calls.append(spec)
            return answer(spec, &state) ?? .notLaunched("\(spec.executable) is not installed")
        }
        return ScriptedCommand(result: result)
    }

    private func answer(_ spec: CommandSpec, _ state: inout State) -> CommandResult? {
        if spec.executable == "nvidia-smi", spec.arguments.first?.hasPrefix("--query-gpu") == true {
            state.gpuReadings += 1
            if state.gpuReadings > 1, let used = state.usedAfterFirstReading { state.machine.usedMB = used }
        }
        if spec.executable == "docker" {
            switch spec.arguments.first {
            case "run":
                if let failure = state.runFails { return CommandResult(status: 125, error: failure) }
                state.machine.container = "running"
                return CommandResult(output: "0123456789abcdef\n")
            case "stop":
                if !state.stopLeavesContainer, spec.arguments.last == VoiceRequirements.containerName { state.machine.container = nil }
                return CommandResult(output: "\(VoiceRequirements.containerName)\n")
            case "rm":
                if spec.arguments.last == VoiceRequirements.containerName { state.machine.container = nil }
                return CommandResult()
            case "logs": return CommandResult(output: state.logs)
            case "pull": return CommandResult(output: "latest: Pulling from x\n")
            default: break
            }
        }
        return state.machine.reply(spec)
    }
}
