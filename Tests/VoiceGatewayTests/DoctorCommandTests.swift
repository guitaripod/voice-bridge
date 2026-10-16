import Foundation
import SetupKit
import Testing
@testable import VoiceGatewayCore

struct DoctorCommandTests {
    func report(_ machine: FakeMachine, managed: Bool = true, nim: NIMProbeResult = .down("not reachable")) async -> SetupReport {
        let root = FakeRoot(machine)
        let (probe, _) = MachineProbe.fake(machine, root: root, nim: nim)
        let mode: EngineMode = managed ? .managed : .external
        return await DoctorCommand.diagnose(probe: probe, settings: EngineSettings(mode: mode), clock: ManualClock())
    }

    func text(_ machine: FakeMachine, unicode: Bool = true) async -> (String, Int32) {
        let outcome = DoctorCommand.outcome(await report(machine), options: .init(), unicode: unicode)
        return (outcome.text, outcome.status)
    }

    @Test func aMachineThatCanRunVoiceSaysSoFirstAndExitsZero() async {
        let (output, status) = await text(FakeMachine())
        #expect(status == 0)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "This machine has an NVIDIA RTX PRO 6000 Blackwell Workstation Edition with 96 GB: voice calls can run here.")
        #expect(output.contains("  ✓ GPU: NVIDIA RTX PRO 6000 Blackwell Workstation Edition\n"))
        #expect(output.contains("  ✓ GPU memory: 96 GB (the voice model needs a card with 64 GB)\n"))
        #expect(output.contains("  ✓ Docker: works for this user\n"))
        #expect(output.contains("  ✓ GPU for containers: set up\n"))
        #expect(output.contains("  ✓ Voice model: downloaded (47 GB)\n"))
        #expect(output.contains("  ✓ Voice engine image: downloaded (23 GB)\n"))
        #expect(output.contains("  ✓ Voice engine: stopped, a call starts it when needed\n"))
        #expect(output.contains("  ✓ voice-bridge \(GatewayInfo.version)\n"))
        #expect(output.hasSuffix("Everything is in place. Open Tailscode and start a call.\n"))
    }

    @Test func noGPUIsTheHonestVerdictAndExitThree() async {
        var machine = FakeMachine()
        machine.gpuName = nil
        let (output, status) = await text(machine)
        #expect(status == 3)
        #expect(output.hasPrefix("No NVIDIA GPU with 64 GB: voice calls cannot run on this machine. nvidia-smi found no NVIDIA GPU.\n"))
        #expect(output.contains("  ✗ GPU: none found (nvidia-smi did not answer)\n"))
        #expect(!output.contains("Docker"))
        #expect(!output.contains("Voice model"))
        #expect(output.hasSuffix("Nothing else was checked, because voice calls cannot run on this machine.\n"))
    }

    @Test func aSmallCardNamesItAndExitsThree() async {
        var machine = FakeMachine()
        machine.gpuName = "NVIDIA L40S"
        machine.totalMB = 46_068
        let (output, status) = await text(machine)
        #expect(status == 3)
        #expect(output.hasPrefix("No NVIDIA GPU with 64 GB: voice calls cannot run on this machine. The card here, an NVIDIA L40S, has 45 GB.\n"))
        #expect(output.contains("  ✗ GPU memory: 45 GB, too small (the voice model needs a card with 64 GB)\n"))
    }

    @Test func aCardWithoutNVIDIAInItsNameIsStillCalledOne() async {
        var machine = FakeMachine()
        machine.gpuName = "GeForce RTX 4090"
        machine.totalMB = 24_564
        let (output, _) = await text(machine)
        #expect(output.contains("The card here, an NVIDIA GeForce RTX 4090, has 24 GB."))
    }

    @Test func aMachineWithNothingInstalledGivesTheCommandsAndTheTailscodeNote() async {
        var machine = FakeMachine()
        machine.docker = .missing
        machine.toolkit = false
        machine.cdiDevices = false
        machine.imageBytes = nil
        machine.model = .absent
        let (output, status) = await text(machine)
        #expect(status == 0)
        #expect(output.contains("  ✗ Docker: not installed\n"))
        #expect(output.contains("      Run: sudo pacman -S --needed docker nvidia-container-toolkit"))
        #expect(output.contains("      Installing system packages, starting the Docker service and joining the docker group need administrator rights.\n"))
        #expect(output.contains("  ✗ GPU for containers: the NVIDIA Container Toolkit is not installed\n"))
        #expect(output.contains("      Run: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml\n"))
        #expect(output.contains("  ○ Voice model: not downloaded yet (47 GB, about 15 minutes). Tailscode will do this for you.\n"))
        #expect(output.contains("  ○ Voice engine image: waits for Docker\n"))
        #expect(output.contains("  ○ Voice engine: waits for the steps above\n"))
        #expect(output.hasSuffix("Run the commands above that need administrator rights, then open Tailscode, pick this server and tap Set up voice.\n"))
    }

    @Test(arguments: [(DockerState.denied, "installed, but this user is not allowed to use it"), (.stopped, "installed, but not running")])
    func dockerThatIsThereButUnusableIsNotCalledMissing(state: DockerState, words: String) async {
        var machine = FakeMachine()
        machine.docker = state
        let (output, _) = await text(machine)
        #expect(output.contains("  ✗ Docker: \(words)\n"))
    }

    @Test func aMachineWhoseOnlyGapsAreDownloadsHandsThemToTailscode() async {
        var machine = FakeMachine()
        machine.imageBytes = nil
        machine.model = .partial(10_000_000_000)
        let (output, _) = await text(machine)
        #expect(output.contains("  ○ Voice model: partly downloaded (47 GB, about 12 minutes). Tailscode will do this for you.\n"))
        #expect(output.contains("  ○ Voice engine image: not downloaded yet (23 GB, about 10 minutes). Tailscode will do this for you.\n"))
        #expect(output.hasSuffix("Open Tailscode, pick this server and tap Set up voice: it does the rest.\n"))
    }

    @Test func aBusyGPUNamesWhoHoldsItAndSaysTheGatewayWillNotStopThem() async {
        var machine = FakeMachine()
        machine.usedMB = 58_562
        machine.holders = [.init(name: "/usr/bin/python3", mb: 30_000), .init(name: "VLLM::EngineCore", mb: 25_000)]
        let (output, status) = await text(machine)
        #expect(status == 0)
        #expect(output.contains("  ✗ Voice engine: the GPU is held by python3, VLLM::EngineCore (38 GB free, the voice model needs 62 GB)\n"))
        #expect(output.contains("never stops another program's job"))
        #expect(output.hasSuffix("Everything is installed. Once the GPU is free again, a call starts the voice engine.\n"))
    }

    @Test func anEngineYouRunYourselfVouchesForTheLocalSteps() async {
        var machine = FakeMachine()
        machine.docker = .missing
        machine.model = .absent
        let output = DoctorCommand.outcome(await report(machine, managed: false, nim: .ready), options: .init(), unicode: true).text
        #expect(output.contains("  ✓ Docker: not needed, a voice engine you run yourself is answering\n"))
        #expect(output.contains("  ✓ Voice engine: running, started by you\n"))
    }

    @Test func withoutUnicodeTheMarksAreAscii() async {
        var machine = FakeMachine()
        machine.model = .absent
        let (output, _) = await text(machine, unicode: false)
        #expect(output.contains("  + GPU: NVIDIA RTX"))
        #expect(output.contains("  o Voice model: not downloaded yet"))
        #expect(output.allSatisfy { $0.isASCII })
    }

    @Test func jsonIsTheSetupReportAndKeepsTheExitCode() async throws {
        var machine = FakeMachine()
        machine.gpuName = nil
        let setup = await report(machine)
        let outcome = DoctorCommand.outcome(setup, options: .init(json: true), unicode: true)
        #expect(outcome.status == 3)
        #expect(outcome.text.hasSuffix("\n"))
        let decoded = try SetupCodec.decode(SetupReport.self, from: Data(outcome.text.utf8))
        #expect(decoded == setup)
        #expect(!decoded.available)
    }

    @Test func commandsListsOnlyWhatNeedsAdministratorRightsOncePerLine() async {
        var machine = FakeMachine()
        machine.docker = .missing
        machine.toolkit = false
        machine.cdiDevices = false
        let outcome = DoctorCommand.outcome(await report(machine), options: .init(commands: true), unicode: true)
        let lines = outcome.text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("sudo pacman -S"))
        #expect(lines[1] == "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml")
        let ready = DoctorCommand.outcome(await report(FakeMachine()), options: .init(commands: true), unicode: true)
        #expect(ready.text.isEmpty && ready.status == 0)
        var gpuless = FakeMachine()
        gpuless.gpuName = nil
        let none = DoctorCommand.outcome(await report(gpuless), options: .init(commands: true), unicode: true)
        #expect(none.text.isEmpty && none.status == 3)
    }

    @Test func theWholeCommandReadsTheMachineThroughTheRunnerAndTheEnvironment() async {
        var machine = FakeMachine()
        machine.imageBytes = nil
        let root = FakeRoot(machine)
        let snapshot = machine
        let runner = ScriptedRunner { snapshot.reply($0) }
        let environment = ["HOME": root.url.path, "VOICE_ENGINE": "managed"]
        let outcome = await DoctorCommand.run(
            options: .init(), environment: environment, unicode: true, runner: runner, nim: FakeNIMProbe(.down("not reachable")))
        #expect(outcome.status == 0)
        #expect(outcome.text.contains("  ○ Voice engine image: not downloaded yet"))
        #expect(runner.called("docker").count > 0)
        #expect(runner.called("docker").allSatisfy { ["version", "image", "ps"].contains($0.arguments.first) })
    }

    @Test func theLocaleDecidesWhetherTheMarksAreUnicode() {
        #expect(DoctorCommand.terminalUnicode(environment: ["LANG": "en_US.UTF-8"]))
        #expect(DoctorCommand.terminalUnicode(environment: ["LC_ALL": "C.utf8", "LANG": "C"]))
        #expect(!DoctorCommand.terminalUnicode(environment: ["LANG": "C"]))
        #expect(!DoctorCommand.terminalUnicode(environment: [:]))
    }

    @Test func theEnvFileUnderTheRealEnvironmentSetsWhatTheServiceWouldSee() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
            # comment
            VOICE_PORT=4999
            export VOICE_PASSWORD="s e c r e t"
            VOICE_MODEL_DIR='/data/model'
            not a setting
            """.write(to: file, atomically: true, encoding: .utf8)
        let layered = EnvFile.layered(over: ["VOICE_ENV_FILE": file.path, "VOICE_PORT": "4888"])
        #expect(layered["VOICE_PORT"] == "4888")
        #expect(layered["VOICE_PASSWORD"] == "s e c r e t")
        #expect(layered["VOICE_MODEL_DIR"] == "/data/model")
        #expect(EnvFile.layered(over: ["VOICE_ENV_FILE": "/nonexistent/x.env"]) == ["VOICE_ENV_FILE": "/nonexistent/x.env"])
        #expect(EnvFile.path(environment: ["HOME": "/home/x"]) == "/home/x/.config/voice-bridge.env")
    }
}
