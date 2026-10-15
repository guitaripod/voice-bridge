import Foundation

struct UtteranceMark: Sendable, Equatable {
    var index: Int
    var kind: String
    var wav: String
    var pass: Int
    var startT: Double
    var endT: Double
}

struct ToolCallResult: Sendable, Equatable {
    var name: String
    var arguments: String
    var output: String
}

struct UtteranceResult: Sendable, Equatable {
    var mark: UtteranceMark
    var speechStoppedMs: Double?
    var firstAudioMs: Double?
    var userTranscript: String
    var toolCalls: [ToolCallResult]
    var modelTranscript: String
    var audioMs: Double
    var tailAfterDone: Bool
    var overlong: Bool
    var errors: [String]

    var runaway: Bool { tailAfterDone || overlong }
}

/// Turns the event timeline into one record per streamed utterance. An utterance owns everything
/// from its first sample until the next one starts.
enum ProbeAnalysis {
    static func utterances(
        events: [TimedEvent], tools: [ToolCallRecord], marks: [UtteranceMark], runEnd: Double, limits: GatewayLimits
    ) -> [UtteranceResult] {
        let tails = tailTimes(events, limits: limits)
        return marks.enumerated().map { position, mark in
            let end = position + 1 < marks.count ? marks[position + 1].startT : runEnd
            let window = events.filter { $0.t >= mark.startT && $0.t < end }
            return result(mark: mark, window: window, tools: tools.filter { $0.t >= mark.startT && $0.t < end },
                tails: tails.filter { $0 >= mark.startT && $0 < end }, limits: limits)
        }
    }

    private static func result(
        mark: UtteranceMark, window: [TimedEvent], tools: [ToolCallRecord], tails: [Double], limits: GatewayLimits
    ) -> UtteranceResult {
        var user: [String] = []
        var said: [String] = []
        var deltas = TextAccumulator()
        var audioBytes = 0
        var firstAudio: Double?
        var stopped: Double?
        var errors: [String] = []
        for item in window {
            switch item.event {
            case .userTranscriptCompleted(_, let text): user.append(text.trimmingCharacters(in: .whitespaces))
            case .transcriptDone(let text): said.append(text)
            case .transcriptDelta(let delta): deltas.append(delta)
            case .audioDelta(let pcm):
                audioBytes += pcm.count
                if firstAudio == nil && item.t >= mark.endT { firstAudio = item.t }
            case .speechStopped: if stopped == nil && item.t >= mark.endT - 0.5 { stopped = item.t }
            case .error(let code, let message): errors.append("\(code): \(message)")
            default: break
            }
        }
        let audioMs = Double(audioBytes) / Double(PCM.bytesPerSecond) * 1000
        return UtteranceResult(
            mark: mark,
            speechStoppedMs: stopped.map { ($0 - mark.endT) * 1000 },
            firstAudioMs: firstAudio.map { ($0 - mark.endT) * 1000 },
            userTranscript: user.filter { !$0.isEmpty }.joined(separator: " "),
            toolCalls: tools.map { ToolCallResult(name: $0.name, arguments: $0.arguments, output: $0.output) },
            modelTranscript: said.isEmpty ? deltas.text : said.joined(separator: " "),
            audioMs: audioMs,
            tailAfterDone: !tails.isEmpty,
            overlong: audioMs > limits.runawaySpeechSeconds * 1000,
            errors: errors)
    }

    /// When the model produced audio more than the tail limit after a response said it was done.
    static func tailTimes(_ events: [TimedEvent], limits: GatewayLimits) -> [Double] {
        var doneAt: Double?
        var flagged: [Double] = []
        for item in events {
            switch item.event {
            case .responseCreated: doneAt = nil
            case .responseDone: doneAt = item.t
            case .audioDelta:
                if let doneAt, item.t - doneAt > limits.runawayTailSeconds { flagged.append(item.t) }
            default: break
            }
        }
        return flagged
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
