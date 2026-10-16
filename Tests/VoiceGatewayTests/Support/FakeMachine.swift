import Foundation
import Synchronization
@testable import VoiceGatewayCore

/// A whole machine in a value: what `nvidia-smi`, `docker`, `nvidia-ctk` and `df` would say, plus a
/// temporary directory holding the model, `os-release` and the CDI spec directory.
struct FakeMachine: Sendable {
    struct Holder: Sendable {
        var pid = 4242
        var name: String
        var mb: Int
    }

    var gpuName: String? = "NVIDIA RTX PRO 6000 Blackwell Workstation Edition"
    var totalMB = 97_887
    var usedMB = 1_200
    var holders: [Holder] = []
    var os = "arch"
    var docker = DockerState.ready
    var toolkit = true
    var cdiDevices = true
    var imageBytes: Int64? = 22_543_587_937
    var container: String?
    var freeDiskMB = 500_000
    var model = ModelShape.complete

    enum ModelShape: Sendable, Equatable {
        case absent
        case partial(Int64)
        case complete
    }

    func reply(_ spec: CommandSpec) -> CommandResult? {
        switch spec.executable {
        case "nvidia-smi": return smi(spec)
        case "docker": return dockerReply(spec)
        case "nvidia-ctk":
            guard toolkit else { return nil }
            return CommandResult(output: cdiDevices ? "nvidia.com/gpu=0\nnvidia.com/gpu=all\n" : "")
        case "df": return CommandResult(output: "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 999 1 \(freeDiskMB * 1_024) 1% /\n")
        default: return nil
        }
    }

    private func smi(_ spec: CommandSpec) -> CommandResult? {
        guard let gpuName else { return CommandResult(status: 9, error: "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.") }
        if spec.arguments.first?.hasPrefix("--query-gpu") == true {
            return CommandResult(output: "\(gpuName), \(totalMB), \(usedMB)\n")
        }
        return CommandResult(output: holders.map { "\($0.pid), \($0.name), \($0.mb)" }.joined(separator: "\n"))
    }

    private func dockerReply(_ spec: CommandSpec) -> CommandResult? {
        switch docker {
        case .missing: return nil
        case .denied: return CommandResult(status: 1, error: "permission denied while trying to connect to the Docker daemon socket")
        case .stopped: return CommandResult(status: 1, error: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")
        case .ready: break
        }
        switch spec.arguments.first {
        case "version": return CommandResult(output: "29.8.2\n")
        case "image":
            guard let imageBytes else { return CommandResult(status: 1, error: "Error: No such image") }
            return CommandResult(output: "\(imageBytes)\n")
        case "ps":
            guard let container else { return CommandResult(output: "open-webui|running|Up 18 hours\n") }
            return CommandResult(output: "open-webui|running|Up 18 hours\n\(VoiceRequirements.containerName)|\(container)|Up 3 minutes\n")
        default: return nil
        }
    }
}

/// The directories a `FakeMachine` lives in.
final class FakeRoot: Sendable {
    let url: URL
    let paths: MachinePaths

    init(_ machine: FakeMachine = FakeMachine()) {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice-bridge-\(UUID().uuidString)", isDirectory: true)
        let cdi = url.appendingPathComponent("cdi", isDirectory: true)
        try? FileManager.default.createDirectory(at: cdi, withIntermediateDirectories: true)
        let osRelease = url.appendingPathComponent("os-release")
        try? "NAME=\"x\"\nID=\(machine.os)\n".write(to: osRelease, atomically: true, encoding: .utf8)
        paths = MachinePaths(home: url, osRelease: osRelease, cdiDirectories: [cdi])
        Self.lay(machine.model, at: paths.modelDir)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    static func lay(_ shape: FakeMachine.ModelShape, at directory: URL) {
        let triton = directory.appendingPathComponent(VoiceRequirements.tritonModel, isDirectory: true)
        let weights = triton.appendingPathComponent("1", isDirectory: true)
        switch shape {
        case .absent:
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        case .partial(let bytes):
            try? FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
            sparse(weights.appendingPathComponent("perception.safetensors"), bytes: bytes)
        case .complete:
            try? FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
            try? "name: \"nemotron-voicechat\"".write(to: triton.appendingPathComponent("config.pbtxt"), atomically: true, encoding: .utf8)
            sparse(weights.appendingPathComponent("perception.safetensors"), bytes: VoiceRequirements.modelBytes)
        }
    }

    static func sparse(_ file: URL, bytes: Int64) {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        try? handle.truncate(atOffset: UInt64(bytes))
        try? handle.close()
    }
}

extension MachineProbe {
    static func fake(_ machine: FakeMachine = FakeMachine(), root: FakeRoot, nim: NIMProbeResult = .down("not reachable")) -> (MachineProbe, ScriptedRunner) {
        let runner = ScriptedRunner { machine.reply($0) }
        return (MachineProbe(runner: runner, paths: root.paths, nim: FakeNIMProbe(nim)), runner)
    }
}
