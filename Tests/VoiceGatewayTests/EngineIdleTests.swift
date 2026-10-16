import Foundation
import Synchronization
import Testing
@testable import VoiceGatewayCore

@Suite(.serialized)
struct EngineIdleTests {
    static var runningMachine: FakeMachine {
        var machine = FakeMachine()
        machine.container = "running"
        machine.usedMB = 70_000
        return machine
    }

    func monitored(_ fixture: EngineFixture) -> Task<Void, Never> {
        let engine = fixture.engine
        return Task { await engine.monitor() }
    }

    @Test func anEngineNobodyWantsStopsAfterTenMinutes() async {
        let fixture = EngineFixture(Self.runningMachine, nim: .ready)
        let monitor = monitored(fixture)
        defer { monitor.cancel() }
        await fixture.advance(9 * 60)
        #expect(fixture.host.stops.isEmpty)
        let stopped = await fixture.advance(until: { !fixture.host.stops.isEmpty }, step: 5)
        #expect(stopped)
        #expect(fixture.host.stops.map(\.arguments) == [["stop", "nemotron-labs-voicechat"]])
        await fixture.advance(120)
        #expect(fixture.host.stops.count == 1)
        #expect(fixture.host.machine.container == nil)
    }

    @Test func aCallInProgressKeepsItRunningAndTheEndOfTheCallRestartsTheClock() async {
        let fixture = EngineFixture(Self.runningMachine, nim: .ready)
        let monitor = monitored(fixture)
        defer { monitor.cancel() }
        fixture.activity.callBegan(at: fixture.clock.now())
        await fixture.advance(30 * 60, step: 15)
        #expect(fixture.host.stops.isEmpty)
        fixture.activity.callEnded(at: fixture.clock.now())
        await fixture.advance(9 * 60, step: 15)
        #expect(fixture.host.stops.isEmpty)
        #expect(await fixture.advance(until: { !fixture.host.stops.isEmpty }, step: 5))
    }

    @Test func aSetupJobKeepsItRunning() async {
        let busy = JobFlag()
        busy.set(true)
        let fixture = EngineFixture(Self.runningMachine, nim: .ready, jobsActive: { busy.value })
        let monitor = monitored(fixture)
        defer { monitor.cancel() }
        await fixture.advance(30 * 60, step: 15)
        #expect(fixture.host.stops.isEmpty)
        busy.set(false)
        await fixture.advance(9 * 60, step: 15)
        #expect(fixture.host.stops.isEmpty)
        #expect(await fixture.advance(until: { !fixture.host.stops.isEmpty }, step: 5))
    }

    @Test func zeroMinutesNeverStopsIt() async {
        let fixture = EngineFixture(Self.runningMachine, nim: .ready, idleMinutes: 0)
        let monitor = monitored(fixture)
        defer { monitor.cancel() }
        await fixture.advance(60 * 60, step: 30)
        #expect(fixture.host.stops.isEmpty)
    }

    @Test func anExternalEngineIsNeverStopped() async {
        let fixture = EngineFixture(Self.runningMachine, mode: .external, nim: .ready)
        let monitor = monitored(fixture)
        defer { monitor.cancel() }
        await fixture.advance(30 * 60, step: 15)
        #expect(fixture.host.stops.isEmpty)
        #expect(await fixture.engine.status().managed == false)
    }

    @Test func aContainerWithALookalikeNameIsNotOurs() async {
        var machine = FakeMachine()
        machine.otherContainers = ["nemotron-labs-voicechat-old", "nemotron-labs-voicechat2", "open-webui"]
        let fixture = EngineFixture(machine, nim: .ready)
        let monitor = monitored(fixture)
        defer { monitor.cancel() }
        await fixture.advance(30 * 60, step: 15)
        #expect(fixture.host.stops.isEmpty)
        #expect(fixture.host.calls.filter { $0.executable == "docker" && ["stop", "rm", "kill"].contains($0.arguments.first ?? "") }.isEmpty)
    }

    @Test func everyDestructiveCommandNamesOnlyOurContainer() async {
        let fixture = EngineFixture(EngineManagerTests.busyMachine)
        _ = await fixture.engine.requestStart()
        var machine = fixture.host.machine
        machine.container = "exited"
        machine.usedMB = 100
        fixture.host.machine = machine
        await fixture.facts.forget()
        _ = await fixture.engine.requestStart()
        let monitor = monitored(fixture)
        defer { monitor.cancel() }
        fixture.nim.result = .ready
        await fixture.advance(20 * 60, step: 5)
        let destructive = fixture.host.calls.filter { $0.executable == "docker" && ["stop", "rm", "kill", "restart"].contains($0.arguments.first ?? "") }
        #expect(!destructive.isEmpty)
        for command in destructive { #expect(command.arguments.last == "nemotron-labs-voicechat") }
        #expect(destructive.allSatisfy { $0.arguments.filter { $0.hasPrefix("nemotron") }.count == 1 })
    }

    @Test func autoModeLeavesAnEngineThatAlreadyAnswersToItsOwner() async {
        let fixture = EngineFixture(FakeMachine(), mode: .auto, nim: .ready)
        let status = await fixture.engine.status()
        #expect(status.managed == false)
        #expect(status.status == .ready)
        let monitor = monitored(fixture)
        defer { monitor.cancel() }
        await fixture.advance(30 * 60, step: 15)
        #expect(fixture.host.stops.isEmpty)
        #expect(await fixture.engine.requestStart() == .external)
    }

    @Test func autoModeManagesWhenNothingAnswers() async {
        let fixture = EngineFixture(FakeMachine(), mode: .auto, nim: .down("no"))
        #expect(await fixture.engine.status().managed)
        #expect(await fixture.engine.status().status == .stopped)
    }

    @Test func autoModeManagesAContainerThatIsOursEvenIfItAnswers() async {
        let fixture = EngineFixture(Self.runningMachine, mode: .auto, nim: .ready)
        #expect(await fixture.engine.status().managed)
    }

    @Test func theDecisionIsMadeOnceAndKept() async {
        let fixture = EngineFixture(FakeMachine(), mode: .auto, nim: .ready)
        #expect(await fixture.engine.status().managed == false)
        fixture.nim.result = .down("later")
        await fixture.facts.forget()
        #expect(await fixture.engine.status().managed == false)
    }

    @Test func onlyTheLocalPortNineThousandCanBeManaged() {
        #expect(EngineMode.effective(.auto, nimURL: "ws://127.0.0.1:9000/v1/realtime") == .auto)
        #expect(EngineMode.effective(.managed, nimURL: "ws://localhost:9000/v1/realtime") == .managed)
        #expect(EngineMode.effective(.managed, nimURL: "ws://gpu-box:9000/v1/realtime") == .external)
        #expect(EngineMode.effective(.auto, nimURL: "ws://127.0.0.1:9100/v1/realtime") == .external)
        #expect(EngineMode.effective(.external, nimURL: "ws://127.0.0.1:9000/v1/realtime") == .external)
        #expect(EngineMode.effective(.auto, nimURL: "nonsense") == .external)
    }

    @Test func configurationReadsTheEngineVariables() {
        let config = GatewayConfig(environment: ["VOICE_ENGINE": "Managed", "VOICE_IDLE_STOP_MINUTES": "3.5"])
        #expect(config.engine == .managed)
        #expect(config.idleStopMinutes == 3.5)
        let defaults = GatewayConfig(environment: [:])
        #expect(defaults.engine == .auto)
        #expect(defaults.idleStopMinutes == 10)
        #expect(GatewayConfig(environment: ["VOICE_ENGINE": "nonsense", "VOICE_IDLE_STOP_MINUTES": "-4"]).engine == .auto)
        #expect(GatewayConfig(environment: ["VOICE_IDLE_STOP_MINUTES": "-4"]).idleStopMinutes == 10)
        #expect(GatewayConfig(port: 1).engine == .external)
    }
}

final class JobFlag: Sendable {
    private let flag = Mutex(false)
    var value: Bool { flag.withLock { $0 } }
    func set(_ value: Bool) { flag.withLock { $0 = value } }
}
