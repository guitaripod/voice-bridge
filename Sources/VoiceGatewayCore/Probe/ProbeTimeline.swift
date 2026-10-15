import Foundation
import VoiceKit

struct TimedEvent: Sendable, Equatable {
    let t: Double
    let event: NIMEvent
}

struct ToolCallRecord: Sendable, Equatable {
    let t: Double
    let name: String
    let arguments: String
    let output: String
}

/// Everything the NIM said during a probe run, stamped in seconds from the start, and the tool
/// calls it was answered with. Tools answer exactly as the gateway's do.
actor ProbeTimeline {
    private(set) var events: [TimedEvent] = []
    private(set) var tools: [ToolCallRecord] = []
    private var buffer = DispatchBuffer()
    private var policy: RecyclePolicy
    private(set) var responding = false
    private(set) var toolPending = false

    init(limits: GatewayLimits) {
        policy = RecyclePolicy(limits: limits)
    }

    func record(_ event: NIMEvent, at t: Double, answeringWith session: NIMSession) {
        events.append(TimedEvent(t: t, event: event))
        switch event {
        case .speechStopped: policy.turnEnded()
        case .userTranscriptCompleted(_, let transcript): buffer.append(transcript)
        case .responseCreated:
            responding = true
            toolPending = false
        case .responseDone: responding = false
        case .audioDelta(let pcm): policy.addAudio(seconds: PCM.seconds(bytes: pcm.count))
        case .functionCall(let callID, let name, let arguments):
            toolPending = true
            let outcome = ToolRouter.run(name: name, agent: AgentCache(), buffer: &buffer)
            tools.append(ToolCallRecord(t: t, name: name, arguments: arguments, output: outcome.output))
            session.answer(callID: callID, output: VoiceText.ascii(outcome.output))
        default: break
        }
    }

    func recordClosed(_ reason: String?, at t: Double) {
        events.append(TimedEvent(t: t, event: .other("socket.closed:\(reason ?? "-")")))
    }

    func sentAudio(seconds: Double) {
        policy.addAudio(seconds: seconds)
    }

    var recycleDue: Bool { policy.due }
    var quiet: Bool { !responding && !toolPending }

    func resetPolicy() {
        policy.reset()
        responding = false
        toolPending = false
    }

    func firstAudio(after t: Double) -> Double? {
        events.first { $0.t >= t && { if case .audioDelta = $0.event { true } else { false } }($0) }?.t
    }
}
