import Foundation
@testable import VoiceGatewayCore

/// An engine manager on a fake host and a manual clock, with the doctor's facts behind it.
final class EngineFixture: Sendable {
    let host: FakeHost
    let root: FakeRoot
    let clock = ManualClock()
    let nim: FakeNIMProbe
    let activity: EngineActivity
    let engine: EngineManager
    let facts: FactsCache

    init(
        _ machine: FakeMachine = FakeMachine(), mode: EngineMode = .managed, nim: NIMProbeResult = .down("not reachable"),
        idleMinutes: Double = 10, llmMemUtil: Double = VoiceRequirements.defaultLLMMemUtil,
        ttsMemUtil: Double = VoiceRequirements.defaultTTSMemUtil, jobsActive: @escaping @Sendable () async -> Bool = { false }
    ) {
        host = FakeHost(machine)
        root = FakeRoot(machine)
        self.nim = FakeNIMProbe(nim)
        activity = EngineActivity(now: clock.now())
        let probe = MachineProbe(runner: host, paths: root.paths, nim: self.nim)
        facts = FactsCache(probe: probe, clock: clock)
        engine = EngineManager(
            settings: EngineSettings(
                mode: mode, idleStopSeconds: idleMinutes * 60, llmMemUtil: llmMemUtil, ttsMemUtil: ttsMemUtil), probe: probe, facts: facts, runner: host,
            nim: self.nim, clock: clock, activity: activity, jobsActive: jobsActive)
    }

    func advance(_ seconds: Double, step: Double = 1) async {
        var left = seconds
        while left > 0 {
            clock.advance(by: min(step, left))
            left -= step
            try? await Task.sleep(for: .milliseconds(3))
        }
    }

    func advance(until condition: @Sendable () async -> Bool, step: Double = 2, timeout: Double = 8) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            clock.advance(by: step)
            try? await Task.sleep(for: .milliseconds(3))
        }
        return await condition()
    }

    func settleLoad(timeout: Double = 5, until: @escaping @Sendable (LoadSnapshot) -> Bool) async -> LoadSnapshot {
        let engine = self.engine
        _ = await eventually(timeout: timeout) { until(await engine.loadSnapshot()) }
        return await engine.loadSnapshot()
    }
}
