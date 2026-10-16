import Foundation
import VoiceKit

public struct ProbeOptions: Sendable {
    public var nimURL: String
    public var wavs: [WavFile]
    public var gapMs = 1500
    public var settleMs = 4000
    public var bargeInMs: Int?
    public var interruptWav: WavFile?
    public var soakSeconds: Int?
    public var instructions = VoiceTools.systemPrompt
    public var tools = VoiceTools.all
    public var summaryTable = false

    public init(nimURL: String, wavs: [WavFile]) {
        self.nimURL = nimURL
        self.wavs = wavs
    }
}

public enum ProbeError: Error, CustomStringConvertible {
    case connect(String)

    public var description: String {
        switch self {
        case .connect(let why): "Cannot open a session on the NIM: \(why)"
        }
    }
}

/// Streams WAVs into the NIM at real-time pace, answers its tool calls like the gateway does, and
/// measures what comes back. It opens sessions with the same code as the gateway and recycles on the
/// same policy, so a soak exercises both.
public actor ProbeRunner {
    private let options: ProbeOptions
    private let connector: any NIMConnector
    private let clock: any VoiceClock
    private let limits: GatewayLimits
    private let timeline: ProbeTimeline
    private let origin: Double
    private var session: NIMSession
    private var consumer: Task<Void, Never>
    private var marks: [UtteranceMark] = []
    private var recycles: [RecycleRecord] = []

    private init(
        options: ProbeOptions, connector: any NIMConnector, clock: any VoiceClock, limits: GatewayLimits,
        session: NIMSession
    ) {
        self.options = options
        self.connector = connector
        self.clock = clock
        self.limits = limits
        self.session = session
        origin = clock.now()
        timeline = ProbeTimeline(limits: limits)
        consumer = Task {}
    }

    public static func run(
        options: ProbeOptions, connector: any NIMConnector = WebSocketNIMConnector(),
        clock: any VoiceClock = SystemVoiceClock(), limits: GatewayLimits = .contract
    ) async throws -> ProbeReport {
        let session: NIMSession
        do {
            session = try await NIMSession.open(
                connector: connector, url: options.nimURL, timeout: limits.nimConnectTimeoutSeconds,
                instructions: options.instructions, tools: options.tools)
        } catch {
            throw ProbeError.connect("\(error)")
        }
        let runner = ProbeRunner(options: options, connector: connector, clock: clock, limits: limits, session: session)
        return try await runner.play()
    }

    private func play() async throws -> ProbeReport {
        let started = Date()
        consumer = attach(session)
        var pass = 0
        var interrupted = false
        let soakEnd = options.soakSeconds.map { Double($0) }
        repeat {
            for wav in options.wavs {
                if let soakEnd, now() >= soakEnd, !marks.isEmpty { break }
                try await recycleIfDue()
                let (start, end) = await stream(wav.pcm)
                marks.append(UtteranceMark(index: marks.count, kind: "utterance", wav: wav.name, pass: pass, startT: start, endT: end))
                if !interrupted, let bargeMs = options.bargeInMs, let interrupt = options.interruptWav {
                    interrupted = true
                    await bargeIn(after: end, delayMs: bargeMs, interrupt: interrupt)
                } else {
                    await stream(silence: options.gapMs)
                }
            }
            pass += 1
        } while soakEnd.map({ now() < $0 }) ?? false
        await stream(silence: options.settleMs)
        consumer.cancel()
        await session.close()
        return await report(started: started)
    }

    private func now() -> Double { clock.now() - origin }

    private func attach(_ session: NIMSession) -> Task<Void, Never> {
        let timeline = self.timeline
        let clock = self.clock
        let origin = self.origin
        return Task {
            for await item in session.events {
                let t = clock.now() - origin
                switch item {
                case .event(let event): await timeline.record(event, at: t, answeringWith: session)
                case .closed(let reason): await timeline.recordClosed(reason, at: t)
                }
            }
        }
    }

    @discardableResult
    private func stream(_ pcm: Data) async -> (Double, Double) {
        let start = now()
        var offset = 0
        var chunk = 0
        while offset < pcm.count {
            let end = min(offset + VoiceWire.preferredChunkBytes, pcm.count)
            chunk += 1
            try? await clock.sleep(until: origin + start + Double(chunk) * 0.08)
            session.appendAudio(pcm[offset..<end])
            offset = end
        }
        await timeline.sentAudio(seconds: PCM.seconds(bytes: pcm.count))
        return (start, now())
    }

    private func stream(silence ms: Int) async {
        guard ms > 0 else { return }
        await stream(Data(count: PCM.bytes(seconds: Double(ms) / 1000)))
    }

    /// Waits for the model to start answering, lets `delayMs` pass, then talks over it.
    private func bargeIn(after speechEnd: Double, delayMs: Int, interrupt: WavFile) async {
        while now() - speechEnd < 15, await timeline.firstAudio(after: speechEnd) == nil {
            await stream(silence: 80)
        }
        if let first = await timeline.firstAudio(after: speechEnd) {
            while now() < first + Double(delayMs) / 1000 { await stream(silence: 80) }
            let (start, end) = await stream(interrupt.pcm)
            marks.append(UtteranceMark(index: marks.count, kind: "interrupt", wav: interrupt.name, pass: 0, startT: start, endT: end))
        }
        await stream(silence: options.gapMs)
    }

    private func recycleIfDue() async throws {
        guard await timeline.recycleDue, await timeline.quiet else { return }
        let started = now()
        consumer.cancel()
        await session.close()
        do {
            session = try await NIMSession.open(
                connector: connector, url: options.nimURL, timeout: limits.nimConnectTimeoutSeconds,
                instructions: options.instructions, tools: options.tools)
        } catch {
            throw ProbeError.connect("recycle failed: \(error)")
        }
        consumer = attach(session)
        await timeline.resetPolicy()
        recycles.append(RecycleRecord(atMs: started * 1000, reopenMs: (now() - started) * 1000))
    }

    private func report(started: Date) async -> ProbeReport {
        let events = await timeline.events
        let end = now()
        let results = ProbeAnalysis.utterances(
            events: events, tools: await timeline.tools, marks: marks, runEnd: end, limits: limits)
        return ProbeReport(
            nim: options.nimURL, startedAt: started, durationSeconds: end, gapMs: options.gapMs,
            settleMs: options.settleMs, soakSeconds: options.soakSeconds, results: results,
            bargeIn: bargeInResult(events), recycles: recycles)
    }

    private func bargeInResult(_ events: [TimedEvent]) -> BargeInResult? {
        guard let interrupt = marks.first(where: { $0.kind == "interrupt" }), let wav = options.interruptWav,
            let delay = options.bargeInMs
        else { return nil }
        let after = events.filter { $0.t >= interrupt.startT }
        let cutoff = after.first { if case .responseCreated = $0.event { true } else { false } }?.t ?? .infinity
        let lastAudio = after.last { item in
            if case .audioDelta = item.event { return item.t < cutoff }
            return false
        }
        let speech = after.first { if case .speechStarted = $0.event { true } else { false } }
        return BargeInResult(
            interruptWav: wav.name, bargeInMs: delay, interruptStartMs: interrupt.startT * 1000,
            speechStartedMs: speech.map { ($0.t - interrupt.startT) * 1000 },
            lastAudioAfterInterruptMs: lastAudio.map { ($0.t - interrupt.startT) * 1000 })
    }
}
