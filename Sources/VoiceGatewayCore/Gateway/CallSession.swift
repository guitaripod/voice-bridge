import Foundation
import Logging
import VoiceKit

/// One call, from the moment the NIM socket is open to the moment the client leaves or the call is
/// ended for cause. All of its state lives here; the watchdogs and the recycle are in its extensions.
actor CallSession {
    let limits: GatewayLimits
    let nimURL: String
    let connector: any NIMConnector
    let clock: any VoiceClock
    let outbox: ClientOutbox
    var logger: Logger

    var nim: NIMSession?
    var generation = 0
    var pumps: [Task<Void, Never>] = []
    var ticker: Task<Void, Never>?
    var recovery: Task<Void, Never>?

    var phase: VoicePhase = .connecting
    var finished = false
    var swapping = false
    var terminal = false

    var agent = AgentCache()
    var buffer = DispatchBuffer()
    var dispatched: [String: String] = [:]
    var userTexts: [String: TextAccumulator] = [:]
    var userCounter = 0
    var loop: LoopDetector
    var runaway: RunawayWatch
    var recycle: RecyclePolicy
    var replay: ReplayBuffer
    var faults: FaultBudget

    var userSpeaking = false
    var responding = false
    var toolPending = false
    var audioCarry = Data()
    var lastClientFrame: Double
    var lastNIMEvent: Double
    var lastActivity: Double

    private let finishedStream: AsyncStream<Void>
    private let finishedSignal: AsyncStream<Void>.Continuation

    init(
        nimURL: String, connector: any NIMConnector, clock: any VoiceClock, limits: GatewayLimits,
        outbox: ClientOutbox, logger: Logger
    ) {
        self.nimURL = nimURL
        self.connector = connector
        self.clock = clock
        self.limits = limits
        self.outbox = outbox
        self.logger = logger
        loop = LoopDetector(limits: limits)
        runaway = RunawayWatch(limits: limits)
        recycle = RecyclePolicy(limits: limits)
        replay = ReplayBuffer(seconds: limits.replayBufferSeconds)
        faults = FaultBudget(limits: limits)
        let now = clock.now()
        lastClientFrame = now
        lastNIMEvent = now
        lastActivity = now
        (finishedStream, finishedSignal) = AsyncStream.makeStream(of: Void.self)
    }

    /// Connects to the NIM. When it cannot, the client is told and the call is over.
    func open() async -> Bool {
        do {
            let session = try await NIMSession.open(
                connector: connector, url: nimURL, timeout: limits.nimConnectTimeoutSeconds)
            install(session)
            return true
        } catch {
            logger.warning("nim unreachable", metadata: ["error": "\(error)"])
            outbox.send(.error(code: "engineDown", message: "The voice engine is not reachable."))
            await finish()
            return false
        }
    }

    func begin() {
        outbox.send(.ready(.init(gateway: GatewayInfo.version, model: GatewayInfo.modelName)))
        setPhase(.listening)
        let start = clock.now() + limits.tickSeconds
        ticker = Task { [weak self] in
            var next = start
            while !Task.isCancelled {
                do { try await self?.clock.sleep(until: next) } catch { return }
                guard let session = self else { return }
                await session.tick()
                next = session.clock.now() + session.limits.tickSeconds
            }
        }
    }

    func waitFinished() async {
        for await _ in finishedStream {}
    }

    func finish() async {
        guard !finished else { return }
        finished = true
        ticker?.cancel()
        recovery?.cancel()
        pumps.forEach { $0.cancel() }
        let session = nim
        nim = nil
        finishedSignal.finish()
        await session?.close()
    }

    func setPhase(_ next: VoicePhase) {
        guard phase != next else { return }
        phase = next
        outbox.send(.phase(next, at: Date().timeIntervalSince1970))
    }

    func install(_ session: NIMSession) {
        generation += 1
        let current = generation
        nim = session
        pumps.forEach { $0.cancel() }
        pumps = [
            Task { [weak self] in
                for await item in session.events {
                    guard let self else { return }
                    await self.nimInbound(item, generation: current)
                }
            }
        ]
    }
}
