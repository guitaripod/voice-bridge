import Foundation

/// One reading of the machine shared by the health route, the checklist and the engine manager, so a
/// screen polling all three does not run `nvidia-smi` and `docker` three times a second.
actor FactsCache {
    private let probe: MachineProbe
    private let clock: any VoiceClock
    private var cached: (facts: MachineFacts, at: Double)?
    private var inflight: Task<MachineFacts, Never>?

    init(probe: MachineProbe, clock: any VoiceClock) {
        self.probe = probe
        self.clock = clock
    }

    func current(maxAge: Double = 2) async -> MachineFacts {
        if let cached, clock.now() - cached.at < maxAge { return cached.facts }
        return await fresh()
    }

    func fresh() async -> MachineFacts {
        if let inflight { return await inflight.value }
        let probe = self.probe
        let task = Task { await probe.facts() }
        inflight = task
        let facts = await task.value
        inflight = nil
        cached = (facts, clock.now())
        return facts
    }

    func forget() {
        cached = nil
    }
}
