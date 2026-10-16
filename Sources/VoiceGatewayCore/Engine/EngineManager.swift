import Foundation
import Logging

struct EngineSettings: Sendable, Equatable {
    var mode: EngineMode = .auto
    var idleStopSeconds: Double = 600
    var typicalLoadSeconds = VoiceRequirements.typicalLoadSeconds
    var loadTimeoutSeconds = VoiceRequirements.loadTimeoutSeconds
    var pollSeconds = 2.0
    var monitorSeconds = 15.0
    var failureMemorySeconds = 120.0
    var stopTimeoutSeconds = 90.0
}

enum LoadSnapshot: Sendable, Equatable {
    case idle
    case loading(Double)
    case ready
    case failed(String)
}

/// Runs the voice container on demand and stops it when it is idle. It only ever touches the container
/// named `nemotron-labs-voicechat`, and it never starts one while the GPU's memory is not free.
actor EngineManager {
    let settings: EngineSettings
    let probe: MachineProbe
    let facts: FactsCache
    let runner: any CommandRunner
    let nim: any NIMHealthProbe
    let clock: any VoiceClock
    let activity: EngineActivity
    let jobsActive: @Sendable () async -> Bool
    let logger: Logger

    var resolved: EngineMode?
    var load = LoadSnapshot.idle
    var failedAt = 0.0
    var loadTask: Task<Void, Never>?

    init(
        settings: EngineSettings, probe: MachineProbe, facts: FactsCache, runner: any CommandRunner, nim: any NIMHealthProbe,
        clock: any VoiceClock, activity: EngineActivity, jobsActive: @escaping @Sendable () async -> Bool = { false },
        logger: Logger = Logger(label: "voice.engine")
    ) {
        self.settings = settings
        self.probe = probe
        self.facts = facts
        self.runner = runner
        self.nim = nim
        self.clock = clock
        self.activity = activity
        self.jobsActive = jobsActive
        self.logger = logger
    }

    func loadSnapshot() -> LoadSnapshot { load }

    /// What the engine is doing and whether this gateway manages it.
    func status() async -> (status: EngineStatus, managed: Bool) {
        let reading = await facts.current()
        let managed = await isManaged(reading)
        return (derive(reading, managed: managed), managed)
    }

    func derive(_ reading: MachineFacts, managed: Bool) -> EngineStatus {
        var loading: Double?
        if case .loading(let progress) = load { loading = progress }
        return EngineStatus.derive(facts: reading, managed: managed, loading: loading, failure: recentFailure())
    }

    func isManaged(_ reading: MachineFacts) async -> Bool {
        if let resolved { return resolved == .managed }
        let mode: EngineMode =
            switch settings.mode {
            case .managed, .external: settings.mode
            case .auto: autoMode(reading)
            }
        resolved = mode
        logger.info("voice engine mode", metadata: ["mode": "\(mode.rawValue)", "configured": "\(settings.mode.rawValue)"])
        return mode == .managed
    }

    /// Managed unless something already answers on the NIM port that is not a container of ours.
    private func autoMode(_ reading: MachineFacts) -> EngineMode {
        if reading.container.exists { return .managed }
        if case .down = reading.nim { return .managed }
        return .external
    }

    private func recentFailure() -> String? {
        guard case .failed(let reason) = load, clock.now() - failedAt < settings.failureMemorySeconds else { return nil }
        return reason
    }
}
