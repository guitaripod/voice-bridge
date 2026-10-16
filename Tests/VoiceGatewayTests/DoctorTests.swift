import Foundation
import SetupKit
import Testing
@testable import VoiceGatewayCore

struct DoctorTests {
    func diagnose(
        _ machine: FakeMachine, nim: NIMProbeResult = .down("not reachable"), managed: Bool = true, jobs: JobsView = JobsView(),
        loading: Double? = nil, failure: String? = nil
    ) async -> SetupReport {
        let root = FakeRoot(machine)
        let (probe, _) = MachineProbe.fake(machine, root: root, nim: nim)
        let facts = await probe.facts()
        let engine = EngineStatus.derive(facts: facts, managed: managed, loading: loading, failure: failure)
        return Doctor(facts: facts, engine: engine, managed: managed, jobs: jobs, version: "9.9.9").report()
    }

    func check(_ report: SetupReport, _ id: String) -> SetupCheck {
        report.checks.first { $0.id == id } ?? SetupCheck(id: "missing:\(id)", state: .unavailable)
    }

    @Test func aMachineWithEverythingIsReadyAndStoppedMeansStartsOnDemand() async {
        let report = await diagnose(FakeMachine())
        #expect(report.capability == "voice")
        #expect(report.available)
        #expect(report.ready)
        #expect(report.job == nil)
        #expect(report.checks.map(\.id) == ["voice.gpu", "voice.vram", "voice.docker", "voice.cdi", "voice.model", "voice.image", "voice.engine", "voice.gateway"])
        #expect(report.checks.allSatisfy { $0.state == .ok })
        #expect(check(report, "voice.gpu").facts == ["name": "NVIDIA RTX PRO 6000 Blackwell Workstation Edition"])
        #expect(check(report, "voice.vram").facts == ["totalMB": "97887", "needMB": "70000"])
        #expect(check(report, "voice.engine").facts["state"] == "stopped")
        #expect(check(report, "voice.gateway").facts == ["version": "9.9.9"])
    }

    @Test func noGPUMeansTheCapabilityCanNeverWork() async {
        var machine = FakeMachine()
        machine.gpuName = nil
        let report = await diagnose(machine)
        #expect(!report.available)
        #expect(!report.ready)
        #expect(check(report, "voice.gpu").state == .unavailable)
        for id in ["voice.vram", "voice.docker", "voice.cdi", "voice.model", "voice.image", "voice.engine"] {
            let item = check(report, id)
            #expect(item.state == .unavailable)
            #expect(item.fix == nil)
        }
        #expect(check(report, "voice.gateway").state == .ok)
    }

    @Test func aSmallCardIsUnavailableWhateverIsFreeOnIt() async {
        var machine = FakeMachine()
        machine.totalMB = 49_140
        machine.usedMB = 0
        let report = await diagnose(machine)
        #expect(!report.available)
        #expect(check(report, "voice.gpu").state == .ok)
        let vram = check(report, "voice.vram")
        #expect(vram.state == .unavailable)
        #expect(vram.facts == ["totalMB": "49140", "needMB": "70000"])
        #expect(check(report, "voice.model").fix == nil)
    }

    @Test func aBigCardThatIsBusyIsStillAvailableAndOnlyTheEngineSaysSo() async {
        var machine = FakeMachine()
        machine.usedMB = 58_562
        machine.holders = [.init(name: "/usr/bin/python3", mb: 30_000), .init(name: "VLLM::EngineCore", mb: 25_000), .init(name: "/usr/bin/kwin_wayland", mb: 367)]
        let report = await diagnose(machine)
        #expect(report.available)
        #expect(check(report, "voice.vram").state == .ok)
        let engine = check(report, "voice.engine")
        #expect(engine.state == .blocked)
        #expect(engine.fix == nil)
        #expect(engine.facts["freeMB"] == "39325")
        #expect(engine.facts["needMB"] == "70000")
        #expect(engine.facts["holders"] == "python3,VLLM::EngineCore")
        #expect(!report.ready)
    }

    @Test(arguments: [
        ("arch", "sudo pacman -S --needed docker nvidia-container-toolkit && sudo systemctl enable --now docker && sudo usermod -aG docker $USER"),
        ("ubuntu", "nvidia.github.io/libnvidia-container"),
        ("debian", "apt-get install -y nvidia-container-toolkit"),
        ("fedora", "docs.nvidia.com/datacenter/cloud-native/container-toolkit"),
    ])
    func noDockerBlocksWithTheCommandForThisOS(os: String, expected: String) async {
        var machine = FakeMachine()
        machine.os = os
        machine.docker = .missing
        let report = await diagnose(machine)
        let docker = check(report, "voice.docker")
        #expect(docker.state == .blocked)
        #expect(docker.facts == ["os": os, "problem": "missing"])
        #expect(docker.fix?.kind == .command)
        #expect(docker.fix?.command?.contains(expected) == true)
        #expect(docker.fix?.reason?.contains("administrator") == true)
        #expect(!report.ready)
    }

    @Test(arguments: [DockerState.denied, .stopped])
    func dockerThatThisUserCannotUseIsBlockedToo(state: DockerState) async {
        var machine = FakeMachine()
        machine.docker = state
        let docker = check(await diagnose(machine), "voice.docker")
        #expect(docker.state == .blocked)
        #expect(docker.facts["problem"] == state.rawValue)
        #expect(docker.fix?.command?.contains("usermod -aG docker") == true)
    }

    @Test func withoutDockerTheImageWaitsAndOffersNothing() async {
        var machine = FakeMachine()
        machine.docker = .denied
        machine.imageBytes = nil
        let report = await diagnose(machine)
        let image = check(report, "voice.image")
        #expect(image.state == .todo)
        #expect(image.fix == nil)
        #expect(image.facts["after"] == "voice.docker")
        let engine = check(report, "voice.engine")
        #expect(engine.state == .todo)
        #expect(engine.facts["after"] == "voice.docker")
    }

    @Test func noCDIDeviceIsBlockedUntilTheCommandIsRun() async {
        var machine = FakeMachine()
        machine.cdiDevices = false
        let cdi = check(await diagnose(machine), "voice.cdi")
        #expect(cdi.state == .blocked)
        #expect(cdi.fix?.command == "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml")
        #expect(cdi.fix?.kind == .command)
        #expect(cdi.fix?.reason?.contains("/etc/cdi") == true)
        #expect(cdi.facts == ["toolkit": "installed"])
    }

    @Test func aMissingToolkitIsSaidInTheFacts() async {
        var machine = FakeMachine()
        machine.toolkit = false
        let cdi = check(await diagnose(machine), "voice.cdi")
        #expect(cdi.state == .blocked)
        #expect(cdi.facts == ["toolkit": "missing"])
    }

    @Test func noModelOffersTheDownloadWithItsSizeAndTime() async {
        var machine = FakeMachine()
        machine.model = .absent
        let model = check(await diagnose(machine), "voice.model")
        #expect(model.state == .todo)
        #expect(model.facts == ["bytes": "0", "needBytes": "46868000000"])
        #expect(model.fix == SetupFix(id: "voice.downloadModel", kind: .job, bytes: 46_868_000_000, minutes: 15))
    }

    @Test func aPartialModelOffersOnlyWhatIsLeft() async {
        var machine = FakeMachine()
        machine.model = .partial(35_000_000_000)
        let model = check(await diagnose(machine), "voice.model")
        #expect(model.state == .todo)
        #expect(model.facts["bytes"] == "35000000000")
        #expect(model.fix?.bytes == 11_868_000_000)
        #expect(model.fix?.minutes == 4)
    }

    @Test func noImageOffersThePull() async {
        var machine = FakeMachine()
        machine.imageBytes = nil
        let image = check(await diagnose(machine), "voice.image")
        #expect(image.state == .todo)
        #expect(image.fix == SetupFix(id: "voice.pullImage", kind: .job, bytes: 22_500_000_000, minutes: 10))
        #expect(check(await diagnose(FakeMachine()), "voice.image").facts["bytes"] == "22543587937")
    }

    @Test func anOpenJobShowsOnTheReportAndOnItsCheckAsWorking() async {
        var machine = FakeMachine()
        machine.model = .partial(5_000_000_000)
        let job = SetupJob(id: "j1", fix: "voice.downloadModel", state: .running, step: "download", fraction: 0.1, startedAt: 5)
        let report = await diagnose(machine, jobs: JobsView(open: [job.fix: job]))
        #expect(report.job == job)
        let model = check(report, "voice.model")
        #expect(model.state == .working)
        #expect(model.facts["job"] == "j1")
        #expect(model.facts["progress"] == "0.10")
        #expect(model.fix == nil)
        #expect(!report.ready)
    }

    @Test func aFailedJobLeavesItsReasonOnTheCheck() async {
        var machine = FakeMachine()
        machine.imageBytes = nil
        let failed = SetupJob(id: "j9", fix: "voice.pullImage", state: .failed, failure: "denied", startedAt: 1)
        let report = await diagnose(machine, jobs: JobsView(lastFailed: [failed.fix: failed]))
        let image = check(report, "voice.image")
        #expect(image.state == .todo)
        #expect(image.facts["lastFailure"] == "denied")
        #expect(image.facts["lastJob"] == "j9")
        #expect(image.fix?.id == "voice.pullImage")
        #expect(report.job == nil)
    }

    @Test func aRunningEngineThatAnswersIsOk() async {
        var machine = FakeMachine()
        machine.container = "running"
        machine.usedMB = 70_000
        let report = await diagnose(machine, nim: .ready)
        #expect(check(report, "voice.engine").state == .ok)
        #expect(check(report, "voice.engine").facts["state"] == "running")
        #expect(report.ready)
    }

    @Test func anEngineThatIsLoadingIsWorkingWithProgress() async {
        var machine = FakeMachine()
        machine.container = "running"
        let started = await diagnose(machine, nim: .loading("x"), loading: 0.42)
        let engine = check(started, "voice.engine")
        #expect(engine.state == .working)
        #expect(engine.facts["progress"] == "0.42")
        #expect(!started.ready)
        let found = check(await diagnose(machine, nim: .loading("x")), "voice.engine")
        #expect(found.state == .working)
        #expect(found.facts["progress"] == nil)
    }

    @Test func aCrashedContainerOrAFailedStartIsDown() async {
        var machine = FakeMachine()
        machine.container = "exited"
        #expect(check(await diagnose(machine), "voice.engine").facts["state"] == "down")
        let failed = check(await diagnose(FakeMachine(), failure: "port is already allocated"), "voice.engine")
        #expect(failed.state == .blocked)
        #expect(failed.facts["reason"] == "port is already allocated")
    }

    @Test func anExternalEngineThatAnswersNeedsNoLocalSteps() async {
        var machine = FakeMachine()
        machine.docker = .missing
        machine.model = .absent
        machine.imageBytes = nil
        machine.cdiDevices = false
        let report = await diagnose(machine, nim: .ready, managed: false)
        #expect(report.ready)
        #expect(check(report, "voice.model").facts == ["mode": "external"])
        #expect(check(report, "voice.engine").facts["mode"] == "external")
    }

    @Test func anExternalEngineThatIsDownIsBlockedWithoutWaitingOnSteps() async {
        var machine = FakeMachine()
        machine.model = .absent
        let engine = check(await diagnose(machine, managed: false), "voice.engine")
        #expect(engine.state == .blocked)
        #expect(engine.facts["state"] == "down")
    }

    @Test func theWireShapeIsStable() throws {
        let check = SetupCheck(id: "voice.vram", state: .ok, facts: ["totalMB": "97887", "needMB": "70000"])
        #expect(String(decoding: try SetupCodec.encode(check), as: UTF8.self) == #"{"facts":{"needMB":"70000","totalMB":"97887"},"id":"voice.vram","state":"ok"}"#)
        let fix = SetupFix(id: "voice.downloadModel", kind: .job, bytes: 46_868_000_000, minutes: 15)
        #expect(String(decoding: try SetupCodec.encode(fix), as: UTF8.self) == #"{"bytes":46868000000,"id":"voice.downloadModel","kind":"job","minutes":15}"#)
        let command = FixCommands.cdi
        #expect(String(decoding: try SetupCodec.encode(command), as: UTF8.self)
            == #"{"command":"sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml","id":"voice.generateCDI","kind":"command","reason":"Describing the GPU to containers writes into /etc/cdi, which needs administrator rights."}"#)
    }

    @Test func aWholeReportRoundTripsThroughTheCodec() async throws {
        var machine = FakeMachine()
        machine.model = .partial(1_000)
        machine.cdiDevices = false
        let report = await diagnose(machine)
        let data = try SetupCodec.encode([report])
        #expect(try SetupCodec.decode([SetupReport].self, from: data) == [report])
    }
}
