import Foundation
import Testing
@testable import VoiceGatewayCore

@Suite(.serialized)
struct EngineManagerTests {
    static let busyMachine: FakeMachine = {
        var machine = FakeMachine()
        machine.usedMB = 58_562
        machine.holders = [.init(name: "VLLM::EngineCore", mb: 50_000), .init(name: "/usr/bin/kwin_wayland", mb: 367)]
        return machine
    }()

    static func isLoading(_ status: EngineStatus) -> Bool {
        if case .loading = status { true } else { false }
    }

    @Test func theContainerIsStartedWithExactlyTheDocumentedCommand() async throws {
        let fixture = EngineFixture()
        let outcome = await fixture.engine.requestStart()
        #expect(outcome == .status(.loading(progress: 0)))
        let run = try #require(fixture.host.runs.first)
        #expect(fixture.host.runs.count == 1)
        #expect(run.executable == "docker")
        #expect(
            run.arguments == [
                "run", "-d", "--name", "nemotron-labs-voicechat", "--device", "nvidia.com/gpu=0", "--shm-size=8GB",
                "-e", "NIM_HTTP_API_PORT=9000", "-e", "LLM_GPU_MEM_UTIL=0.30", "-e", "TTS_GPU_MEM_UTIL=0.25", "-p", "127.0.0.1:9000:9000", "-v", "\(fixture.root.paths.modelDir.path):/data/models",
                "--entrypoint", "/s2s/run_s2s_server.sh", "nvcr.io/nim/nvidia/nemotron-labs-voicechat:latest",
            ])
    }

    @Test func aNestedModelFolderIsWhatGetsMounted() async throws {
        let fixture = EngineFixture(FakeMachine(model: .absent))
        FakeRoot.lay(.complete, at: fixture.root.paths.modelDir.appendingPathComponent(VoiceRequirements.modelFolder))
        _ = await fixture.engine.requestStart()
        let mount = try #require(fixture.host.runs.first?.arguments.first { $0.hasSuffix(":/data/models") })
        #expect(mount == "\(fixture.root.paths.modelDir.appendingPathComponent(VoiceRequirements.modelFolder).path):/data/models")
    }

    @Test func nothingStartsWhileTheGPUIsHeldAndTheHoldersAreNamed() async {
        let fixture = EngineFixture(Self.busyMachine)
        let outcome = await fixture.engine.requestStart()
        #expect(outcome == .status(.busy(freeMB: 39_325, needMB: 62_000, holders: ["VLLM::EngineCore"])))
        #expect(fixture.host.runs.isEmpty)
        #expect(fixture.host.stops.isEmpty)
    }

    @Test func theMemoryIsReadAgainRightBeforeStarting() async {
        let fixture = EngineFixture()
        fixture.host.configure { $0.usedAfterFirstReading = 60_000 }
        let outcome = await fixture.engine.requestStart()
        guard case .status(.busy(let free, _, _)) = outcome else {
            Issue.record("expected busy, got \(outcome)")
            return
        }
        #expect(free == 37_887)
        #expect(fixture.host.runs.isEmpty)
    }

    @Test func exactlyEnoughMemoryStarts() async {
        var machine = FakeMachine()
        machine.totalMB = 97_887
        machine.usedMB = 97_887 - 62_000
        let fixture = EngineFixture(machine)
        #expect(await fixture.engine.requestStart() == .status(.loading(progress: 0)))
        #expect(fixture.host.runs.count == 1)
    }

    @Test func nothingStartsWhileSomethingIsMissing() async {
        let fixture = EngineFixture(FakeMachine(imageBytes: nil))
        #expect(await fixture.engine.requestStart() == .status(.needsSetup))
        var noModel = FakeMachine()
        noModel.model = .absent
        let other = EngineFixture(noModel)
        #expect(await other.engine.requestStart() == .status(.needsSetup))
        #expect(fixture.host.runs.isEmpty && other.host.runs.isEmpty)
    }

    @Test func progressFollowsTimeAgainstAFourMinuteLoadAndEndsWhenTheNIMIsReady() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        await fixture.advance(120)
        guard case .loading(let half) = await fixture.settleLoad(until: { if case .loading(let p) = $0 { p >= 0.45 } else { false } }) else {
            Issue.record("not loading")
            return
        }
        #expect(half >= 0.45 && half <= 0.55)
        #expect(Self.isLoading(await fixture.engine.status().status))
        fixture.nim.result = .ready
        await fixture.advance(4)
        #expect(await fixture.settleLoad(until: { $0 == .ready }) == .ready)
        #expect(await fixture.engine.status().status == .ready)
    }

    @Test func progressNeverReachesOneBeforeTheNIMSaysSo() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        await fixture.advance(400, step: 2)
        guard case .loading(let late) = await fixture.engine.loadSnapshot() else {
            Issue.record("not loading")
            return
        }
        #expect(late == 0.99)
    }

    @Test func aLoadThatNeverFinishesFailsAtEightMinutesAndStopsOnlyOurContainer() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        let engine = fixture.engine
        _ = await fixture.advance(until: { if case .failed = await engine.loadSnapshot() { true } else { false } })
        guard case .failed(let reason) = await fixture.engine.loadSnapshot() else {
            Issue.record("did not fail")
            return
        }
        #expect(reason.contains("8 minutes"))
        #expect(fixture.host.stops.map(\.arguments) == [["stop", "nemotron-labs-voicechat"]])
        let status = await fixture.engine.status().status
        #expect(status == .down(reason: reason))
    }

    @Test func aContainerThatDiesWhileLoadingFailsTheLoad() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        fixture.host.configure { $0.machine.container = nil }
        let engine = fixture.engine
        _ = await fixture.advance(until: { if case .failed = await engine.loadSnapshot() { true } else { false } })
        guard case .failed(let reason) = await fixture.engine.loadSnapshot() else {
            Issue.record("did not fail")
            return
        }
        #expect(reason.contains("stopped while loading"))
    }

    @Test func aStartThatDockerRefusesIsDownWithTheReasonAndRetriedLater() async {
        let fixture = EngineFixture()
        fixture.host.configure { $0.runFails = "docker: Error response from daemon: port is already allocated." }
        let outcome = await fixture.engine.requestStart()
        guard case .status(.down(let reason)) = outcome else {
            Issue.record("expected down, got \(outcome)")
            return
        }
        #expect(reason.contains("port is already allocated"))
        #expect(await fixture.engine.status().status == .down(reason: reason))
        fixture.clock.advance(by: 121)
        #expect(await fixture.engine.status().status == .stopped)
        fixture.host.configure { $0.runFails = nil }
        #expect(await fixture.engine.requestStart() == .status(.loading(progress: 0)))
    }

    @Test func aStaleStoppedContainerOfOursIsRemovedByName() async {
        var machine = FakeMachine()
        machine.container = "exited"
        let fixture = EngineFixture(machine)
        _ = await fixture.engine.requestStart()
        #expect(fixture.host.commands("docker", "rm").map(\.arguments) == [["rm", "-f", "nemotron-labs-voicechat"]])
        #expect(fixture.host.runs.count == 1)
    }

    @Test func aRunningEngineIsLeftAloneAndAnAdoptedLoadIsWatched() async {
        var machine = FakeMachine()
        machine.container = "running"
        machine.usedMB = 70_000
        let fixture = EngineFixture(machine, nim: .loading("x"))
        let outcome = await fixture.engine.requestStart()
        guard case .status(let status) = outcome else {
            Issue.record("expected a status")
            return
        }
        #expect(Self.isLoading(status))
        #expect(fixture.host.runs.isEmpty)
        fixture.nim.result = .ready
        await fixture.advance(4)
        #expect(await fixture.settleLoad(until: { $0 == .ready }) == .ready)
    }

    @Test func readyAlreadyMeansNothingIsDone() async {
        var machine = FakeMachine()
        machine.container = "running"
        let fixture = EngineFixture(machine, nim: .ready)
        #expect(await fixture.engine.requestStart() == .status(.ready))
        #expect(fixture.host.runs.isEmpty)
    }

    @Test func stoppedAndBusyAreWhatAHealthReadingSees() async {
        let free = EngineFixture()
        #expect(await free.engine.status().status == .stopped)
        let held = EngineFixture(Self.busyMachine)
        #expect(await held.engine.status().status == .busy(freeMB: 39_325, needMB: 62_000, holders: ["VLLM::EngineCore"]))
        let missing = EngineFixture(FakeMachine(imageBytes: nil))
        #expect(await missing.engine.status().status == .needsSetup)
    }
}
