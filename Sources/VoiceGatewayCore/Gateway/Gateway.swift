import Foundation
import Logging
import Synchronization
import VoiceKit

/// The gateway's shared state: who holds the one call, what the engine looks like, and how to
/// reach it. Routes and tests both go through it.
public final class Gateway: Sendable {
    public let config: GatewayConfig
    public let limits: GatewayLimits
    let connector: any NIMConnector
    let clock: any VoiceClock
    let monitor: NIMHealthMonitor
    let machine: MachineServices?
    let updates: UpdateChecker
    let logger: Logger
    private let active = Mutex(0)

    public init(
        config: GatewayConfig, limits: GatewayLimits = .contract,
        connector: any NIMConnector = WebSocketNIMConnector(),
        probe: (any NIMHealthProbe)? = nil, machine: MachineServices? = nil, clock: any VoiceClock = SystemVoiceClock(),
        releases: ReleaseList.Fetch? = nil, logger: Logger = Logger(label: "voice-bridge")
    ) {
        self.config = config
        self.limits = limits
        self.connector = connector
        self.clock = clock
        self.logger = logger
        self.machine = machine
        updates = UpdateChecker(clock: clock, fetch: releases ?? ReleaseList.fetcher(base: config.releaseBase))
        monitor = NIMHealthMonitor(
            probe: probe ?? HTTPNIMHealthProbe(nimURL: config.nimURL), clock: clock, ttl: limits.healthCacheSeconds)
    }

    public var calls: Int { active.withLock { $0 } }

    func acquire() -> Bool {
        active.withLock { count in
            guard count == 0 else { return false }
            count = 1
            return true
        }
    }

    func release() {
        active.withLock { $0 = max(0, $0 - 1) }
        machine?.activity.callEnded(at: clock.now())
    }

    func describe(_ detail: String) -> String {
        "\(detail) Dispatch: \(config.effectiveDispatch.rawValue). Speech: \(config.speech.rawValue)."
    }

    public func health() async -> VoiceHealth {
        let held = calls
        if held > 0 {
            return VoiceHealth(
                gateway: GatewayInfo.version, engine: .busy, model: GatewayInfo.modelName, calls: held,
                detail: describe("A call is in progress."))
        }
        if let machine, let mapped = await machineHealth(machine) { return mapped }
        switch await monitor.current() {
        case .ready:
            return VoiceHealth(
                gateway: GatewayInfo.version, engine: .ready, model: GatewayInfo.modelName, calls: 0,
                detail: describe("Ready for a call."))
        case .loading(let detail):
            return VoiceHealth(
                gateway: GatewayInfo.version, engine: .loading, model: GatewayInfo.modelName, calls: 0, detail: describe(detail))
        case .down(let detail):
            return VoiceHealth(
                gateway: GatewayInfo.version, engine: .down, model: GatewayInfo.modelName, calls: 0, detail: describe(detail))
        }
    }
}
