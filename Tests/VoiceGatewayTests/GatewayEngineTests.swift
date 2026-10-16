import Foundation
import Testing
@testable import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct GatewayEngineTests {
    func engineFrames(_ client: TestClient) -> [(VoiceEngineState, Double?)] {
        client.messages.compactMap { if case .engine(let state, let progress) = $0 { (state, progress) } else { nil } }
    }

    func isEngineDown(_ message: VoiceServerMessage) -> Bool {
        if case .error(let code, _) = message { code == "engineDown" } else { false }
    }

    func isReady(_ message: VoiceServerMessage) -> Bool {
        if case .ready = message { true } else { false }
    }

    @Test func healthSaysStoppedWhenEverythingIsThereAndNothingRuns() async throws {
        let harness = await MachineGatewayHarness.start()
        defer { Task { await harness.stop() } }
        let health = try await harness.health()
        #expect(health.engine == .stopped)
        #expect(health.detail?.contains("starts when a call needs it") == true)
        #expect(health.gateway == GatewayInfo.version)
    }

    @Test func healthSaysNeedsSetupWhenSomethingIsMissing() async throws {
        let harness = await MachineGatewayHarness.start(FakeMachine(imageBytes: nil))
        defer { Task { await harness.stop() } }
        #expect(try await harness.health().engine == .needsSetup)
    }

    @Test func healthSaysBusyAndNamesWhoHoldsTheGPU() async throws {
        let harness = await MachineGatewayHarness.start(EngineManagerTests.busyMachine)
        defer { Task { await harness.stop() } }
        let health = try await harness.health()
        #expect(health.engine == .busy)
        #expect(health.detail?.contains("VLLM::EngineCore") == true)
    }

    @Test func healthFollowsALoadingAndAReadyEngine() async throws {
        var machine = FakeMachine()
        machine.container = "running"
        machine.usedMB = 70_000
        let harness = await MachineGatewayHarness.start(machine, nim: .loading("x"))
        defer { Task { await harness.stop() } }
        #expect(try await harness.health().engine == .loading)
        harness.probe.result = .ready
        #expect(try await harness.health().engine == .ready)
    }

    @Test func healthSaysDownWhenTheContainerDied() async throws {
        var machine = FakeMachine()
        machine.container = "exited"
        let harness = await MachineGatewayHarness.start(machine)
        defer { Task { await harness.stop() } }
        #expect(try await harness.health().engine == .down)
    }

    @Test func anExternalEngineKeepsTheOldHealthAnswers() async throws {
        let harness = await MachineGatewayHarness.start(FakeMachine(imageBytes: nil), mode: .external)
        defer { Task { await harness.stop() } }
        #expect(try await harness.health().engine == .ready)
        harness.nim.setHealth(status: 503, body: "")
        harness.clockHandle.advance(by: 3)
        #expect(try await harness.health().engine == .loading)
    }

    @Test func aCallOnARunningEngineGetsNoEngineFramesAndRuns() async throws {
        var machine = FakeMachine()
        machine.container = "running"
        machine.usedMB = 70_000
        let harness = await MachineGatewayHarness.start(machine, nim: .ready)
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.hello()
        #expect(await client.waitFor { self.isReady($0) } != nil)
        #expect(engineFrames(client).isEmpty)
        #expect(harness.host.runs.isEmpty)
        await client.close()
    }

    @Test func aCallOnAStoppedEngineStartsItAndTheClientWatchesItLoad() async throws {
        let harness = await MachineGatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.hello()

        #expect(await client.waitFor { if case .engine(.loading, _) = $0 { true } else { false } } != nil)
        #expect(harness.host.runs.count == 1)
        #expect(harness.gateway.calls == 1)
        #expect(await harness.advance(until: { engineFrames(client).count >= 4 }))
        let frames = engineFrames(client)
        #expect(frames.allSatisfy { $0.0 == .loading })
        let progress = frames.compactMap(\.1)
        #expect(progress.first == 0)
        #expect(progress == progress.sorted())
        #expect(progress.allSatisfy { $0 >= 0 && $0 < 1 })
        #expect(client.messages.allSatisfy { !isReady($0) })

        harness.probe.result = .ready
        #expect(await harness.advance(until: { client.messages.contains { isReady($0) } }))
        #expect(client.messages.allSatisfy { !isEngineDown($0) })
        #expect(await client.waitFor { if case .phase(.listening, _) = $0 { true } else { false } } != nil)
        await client.close()
        #expect(await eventually { harness.gateway.calls == 0 })
    }

    @Test func framesComeEveryTwoSecondsNotFaster() async throws {
        let harness = await MachineGatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.hello()
        #expect(await client.waitFor { if case .engine = $0 { true } else { false } } != nil)
        for _ in 0..<7 {
            harness.clockHandle.advance(by: 0.25)
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(engineFrames(client).count == 1)
        #expect(await harness.advance(until: { engineFrames(client).count == 2 }, step: 0.25))
        await client.close()
    }

    @Test func aBusyGPUIsReportedAndNothingIsStarted() async throws {
        let harness = await MachineGatewayHarness.start(EngineManagerTests.busyMachine)
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.hello()
        let error = await client.waitFor { self.isEngineDown($0) }
        guard case .error(_, let message)? = error else {
            Issue.record("no engineDown error")
            return
        }
        #expect(message.contains("VLLM::EngineCore"))
        #expect(engineFrames(client).map(\.0) == [.busy])
        #expect(await client.waitClosed())
        #expect(harness.host.runs.isEmpty)
        #expect(await eventually { harness.gateway.calls == 0 })
    }

    @Test func aMachineThatNeedsSetupSaysSoAndStartsNothing() async throws {
        var machine = FakeMachine()
        machine.model = .absent
        let harness = await MachineGatewayHarness.start(machine)
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.hello()
        #expect(await client.waitFor { self.isEngineDown($0) } != nil)
        #expect(engineFrames(client).map(\.0) == [.needsSetup])
        #expect(harness.host.runs.isEmpty)
        #expect(await client.waitClosed())
    }

    @Test func aStartThatFailsIsAnEngineDownErrorWithTheReason() async throws {
        let harness = await MachineGatewayHarness.start()
        defer { Task { await harness.stop() } }
        harness.host.configure { $0.runFails = "docker: Error response from daemon: port is already allocated." }
        let client = try await harness.connect()
        client.hello()
        let error = await client.waitFor { self.isEngineDown($0) }
        guard case .error(_, let message)? = error else {
            Issue.record("no engineDown error")
            return
        }
        #expect(message.contains("port is already allocated"))
        #expect(await client.waitClosed())
    }

    @Test func aLoadThatTimesOutIsAnEngineDownError() async throws {
        let harness = await MachineGatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.hello()
        #expect(await harness.advance(until: { client.messages.contains { self.isEngineDown($0) } }, timeout: 15, step: 5))
        #expect(harness.host.stops.map(\.arguments) == [["stop", "nemotron-labs-voicechat"]])
        #expect(await client.waitClosed())
    }

    @Test func aClientThatLeavesWhileItLoadsFreesTheCallAndTheEngineKeepsLoading() async throws {
        let harness = await MachineGatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.connect()
        client.hello()
        #expect(await client.waitFor { if case .engine = $0 { true } else { false } } != nil)
        await client.close()
        #expect(await harness.advance(until: { harness.gateway.calls == 0 }, step: 0.5))
        guard case .loading = await harness.services.engine.loadSnapshot() else {
            Issue.record("the load should go on")
            return
        }
        #expect(harness.host.stops.isEmpty)
        harness.probe.result = .ready
        #expect(await harness.advance(until: { await harness.services.engine.loadSnapshot() == .ready }, step: 2))
        let again = try await harness.connect()
        again.hello()
        #expect(await again.waitFor { self.isReady($0) } != nil)
        #expect(harness.host.runs.count == 1)
        await again.close()
    }

    @Test func aSecondCallerWhileTheFirstWaitsIsToldBusy() async throws {
        let harness = await MachineGatewayHarness.start()
        defer { Task { await harness.stop() } }
        let first = try await harness.connect()
        first.hello()
        #expect(await first.waitFor { if case .engine = $0 { true } else { false } } != nil)
        let second = try await harness.connect()
        second.hello()
        #expect(await second.waitForError("busy"))
        #expect(harness.host.runs.count == 1)
        await first.close()
    }

    @Test func aCallEndingRestartsTheIdleClock() async throws {
        var machine = FakeMachine()
        machine.container = "running"
        machine.usedMB = 70_000
        let harness = await MachineGatewayHarness.start(machine, nim: .ready)
        defer { Task { await harness.stop() } }
        harness.clockHandle.advance(by: 100)
        let client = try await harness.connect()
        client.hello()
        #expect(await client.waitFor { self.isReady($0) } != nil)
        #expect(harness.services.activity.calls == 1)
        harness.clockHandle.advance(by: 50)
        await client.close()
        #expect(await eventually { harness.services.activity.calls == 0 })
        #expect(harness.services.activity.last >= 150)
    }
}
