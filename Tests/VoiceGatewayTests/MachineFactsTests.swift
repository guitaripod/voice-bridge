import Foundation
import Testing
@testable import VoiceGatewayCore

struct MachineFactsTests {
    @Test func theRealisticMachineReadsBackWhole() async {
        var machine = FakeMachine()
        machine.usedMB = 58_562
        machine.holders = [.init(name: "/usr/bin/python", mb: 30_000), .init(name: "/usr/bin/kwin_wayland", mb: 367)]
        let root = FakeRoot(machine)
        let (probe, _) = MachineProbe.fake(machine, root: root, nim: .ready)
        let facts = await probe.facts()
        #expect(facts.gpu?.name == "NVIDIA RTX PRO 6000 Blackwell Workstation Edition")
        #expect(facts.gpu?.freeMB == 39_325)
        #expect(facts.gpu?.holderNames == ["python"])
        #expect(facts.os == OSRelease(id: "arch", family: .arch))
        #expect(facts.docker == .ready)
        #expect(facts.cdi)
        #expect(facts.imageBytes == 22_543_587_937)
        #expect(facts.model.valid)
        #expect(facts.model.bytes >= VoiceRequirements.modelBytes)
        #expect(facts.container == .absent)
        #expect(facts.nim == .ready)
        #expect(facts.setupComplete)
    }

    @Test func noNvidiaSmiAtAllIsNoGPU() async {
        var machine = FakeMachine()
        machine.gpuName = nil
        let root = FakeRoot(machine)
        let (probe, _) = MachineProbe.fake(machine, root: root)
        #expect(await probe.facts().gpu == nil)
    }

    @Test func dockerQueriesAreSkippedWhenDockerIsNotUsable() async {
        var machine = FakeMachine()
        machine.docker = .denied
        let root = FakeRoot(machine)
        let (probe, runner) = MachineProbe.fake(machine, root: root)
        let facts = await probe.facts()
        #expect(facts.docker == .denied)
        #expect(facts.imageBytes == nil)
        #expect(runner.called("docker").count == 1)
    }

    @Test func cdiComesFromTheToolkitOrFromASpecFile() async throws {
        var machine = FakeMachine()
        machine.cdiDevices = false
        let root = FakeRoot(machine)
        let (probe, _) = MachineProbe.fake(machine, root: root)
        #expect(await probe.facts().cdi == false)
        try "cdiVersion: 0.5.0".write(to: root.paths.cdiDirectories[0].appendingPathComponent("nvidia.yaml"), atomically: true, encoding: .utf8)
        #expect(await probe.facts().cdi)

        machine.toolkit = false
        let bare = FakeRoot(machine)
        let (noToolkit, _) = MachineProbe.fake(machine, root: bare)
        let facts = await noToolkit.facts()
        #expect(!facts.toolkitInstalled)
        #expect(!facts.cdi)
    }

    @Test func aPartialModelIsCountedButNotValid() async {
        var machine = FakeMachine()
        machine.model = .partial(12_000_000_000)
        let root = FakeRoot(machine)
        let (probe, _) = MachineProbe.fake(machine, root: root)
        let model = await probe.facts().model
        #expect(model.bytes == 12_000_000_000)
        #expect(!model.valid)
    }

    @Test func aModelFolderUnpackedByNGCCountsToo() async throws {
        let machine = FakeMachine(model: .absent)
        let root = FakeRoot(machine)
        FakeRoot.lay(.complete, at: root.paths.modelDir.appendingPathComponent(VoiceRequirements.modelFolder))
        let status = ModelDirectory.inspect(root.paths.modelDir)
        #expect(status.valid)
        #expect(status.root.lastPathComponent == VoiceRequirements.modelFolder)
    }

    @Test func weightsWithoutAConfigAreNotAModel() async throws {
        let machine = FakeMachine(model: .complete)
        let root = FakeRoot(machine)
        try FileManager.default.removeItem(at: root.paths.modelDir.appendingPathComponent("\(VoiceRequirements.tritonModel)/config.pbtxt"))
        #expect(!ModelDirectory.inspect(root.paths.modelDir).valid)
    }

    @Test func theContainerStateComesFromDockerPS() async {
        var machine = FakeMachine()
        machine.container = "running"
        let root = FakeRoot(machine)
        let (probe, runner) = MachineProbe.fake(machine, root: root)
        #expect(await probe.facts().container == .running)
        let ps = runner.called("docker", "ps").first
        #expect(ps?.arguments.contains("name=nemotron-labs-voicechat") == true)
    }

    @Test func pathsFollowTheEnvironment() {
        let paths = MachinePaths(environment: ["HOME": "/home/x", "VOICE_MODEL_DIR": "/mnt/m"])
        #expect(paths.modelDir.path == "/mnt/m")
        #expect(paths.jobsDir.path == "/home/x/.local/state/voice-bridge/jobs")
        #expect(paths.ngcDir.path == "/home/x/.local/share/voice-bridge/ngc")
        #expect(MachinePaths(environment: ["HOME": "/home/x"]).modelDir.path == "/home/x/.local/share/voice-bridge/model")
    }
}
