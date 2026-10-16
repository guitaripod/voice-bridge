import Foundation
import VoiceKit

struct BargeInResult: Sendable, Equatable {
    var interruptWav: String
    var bargeInMs: Int
    var interruptStartMs: Double
    var speechStartedMs: Double?
    var lastAudioAfterInterruptMs: Double?

    var silenceWithin300: Bool { (lastAudioAfterInterruptMs ?? 0) <= 300 }
}

struct RecycleRecord: Sendable, Equatable {
    var atMs: Double
    var reopenMs: Double
}

/// The measurement record of one probe run. `json` is the stable schema: every key is always
/// present, absent measurements are `null`.
public struct ProbeReport: Sendable {
    public static let schema = "voice-probe/1"

    var nim: String
    var startedAt: Date
    var durationSeconds: Double
    var gapMs: Int
    var settleMs: Int
    var soakSeconds: Int?
    var results: [UtteranceResult]
    var bargeIn: BargeInResult?
    var recycles: [RecycleRecord]

    var spoken: [UtteranceResult] { results.filter { $0.mark.kind == "utterance" } }

    var summary: JSONValue {
        let latencies = spoken.compactMap(\.firstAudioMs)
        let sends = spoken.filter { $0.toolCalls.contains { $0.name == VoiceTools.sendToAgent } }.count
        return .object([
            "utterances": number(spoken.count),
            "answered": number(latencies.count),
            "firstAudioP50Ms": optional(ProbeAnalysis.percentile(latencies, 0.5)),
            "firstAudioP95Ms": optional(ProbeAnalysis.percentile(latencies, 0.95)),
            "sendToAgentCalls": number(sends),
            "sendToAgentRate": .number(spoken.isEmpty ? 0 : Double(sends) / Double(spoken.count)),
            "runaways": number(results.filter(\.runaway).count),
            "modelErrors": number(results.reduce(0) { $0 + $1.errors.count }),
            "recycles": number(recycles.count),
        ])
    }

    public var json: JSONValue {
        .object([
            "schema": .string(Self.schema),
            "nim": .string(nim),
            "startedAt": .string(ISO8601DateFormatter().string(from: startedAt)),
            "durationSeconds": .number(durationSeconds),
            "options": .object([
                "gapMs": number(gapMs), "settleMs": number(settleMs),
                "soakSeconds": soakSeconds.map(number) ?? .null,
            ]),
            "utterances": .array(results.map(utterance)),
            "bargeIn": bargeIn.map(barge) ?? .null,
            "recycles": .array(
                recycles.map { .object(["atMs": .number($0.atMs), "reopenMs": .number($0.reopenMs)]) }),
            "summary": summary,
        ])
    }

    public func pretty() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(json) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public func humanSummary() -> String {
        var lines = ["voice-probe \(nim) (\(String(format: "%.1f", durationSeconds)) s)"]
        for item in results {
            let first = item.firstAudioMs.map { String(format: "%.0f ms", $0) } ?? "no audio"
            let tools = item.toolCalls.map(\.name).joined(separator: ",")
            lines.append(
                "  [\(item.mark.kind) \(item.mark.index)] \(item.mark.wav) first audio \(first), audio \(Int(item.audioMs)) ms, tools [\(tools)]"
                    + (item.runaway ? " RUNAWAY" : "") + "\n      heard: \(item.userTranscript)\n      said: \(item.modelTranscript)")
        }
        if let bargeIn {
            let last = bargeIn.lastAudioAfterInterruptMs.map { String(format: "%.0f ms", $0) } ?? "already silent"
            lines.append("  barge-in: last model audio \(last) after the interrupt started (within 300 ms: \(bargeIn.silenceWithin300))")
        }
        let totals = summary
        let p95 = totals["firstAudioP95Ms"]?.number.map { String(format: "%.0f ms", $0) } ?? "n/a"
        lines.append("  \(spoken.count) utterances, first audio p95 \(p95), \(recycles.count) recycles")
        return lines.joined(separator: "\n")
    }

    /// One plain row per utterance and the totals, for putting two runs side by side.
    public func summaryTable() -> String {
        func clip(_ text: String, _ limit: Int) -> String {
            let one = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return one.count > limit ? String(one.prefix(limit - 1)) + "~" : one
        }
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        let rows = spoken.map { item -> [String] in
            let first = item.firstAudioMs.map { String(format: "%.0f ms", $0) } ?? "-"
            let tools = item.toolCalls.map(\.name).joined(separator: ",")
            return [
                "\(item.mark.index)", item.mark.wav, first, tools.isEmpty ? "-" : tools, item.runaway ? "yes" : "no",
                clip(item.userTranscript, 44), clip(item.modelTranscript, 44),
            ]
        }
        let header = ["#", "wav", "first audio", "tools", "runaway", "heard", "said"]
        let table = [header] + rows
        let widths = header.indices.map { column in table.map { $0[column].count }.max() ?? 0 }
        var lines = table.map { row in
            row.indices.map { pad(row[$0], widths[$0]) }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        let latencies = spoken.compactMap(\.firstAudioMs)
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "n/a" }
        let sends = spoken.filter { $0.toolCalls.contains { $0.name == VoiceTools.sendToAgent } }.count
        lines.append("")
        lines.append(
            "utterances \(spoken.count), answered \(latencies.count), first audio p50 \(ms(ProbeAnalysis.percentile(latencies, 0.5)))"
                + " p95 \(ms(ProbeAnalysis.percentile(latencies, 0.95))), send_to_agent \(sends)/\(spoken.count),"
                + " runaways \(results.filter(\.runaway).count), model errors \(results.reduce(0) { $0 + $1.errors.count }),"
                + " recycles \(recycles.count)")
        return lines.joined(separator: "\n")
    }

    private func utterance(_ item: UtteranceResult) -> JSONValue {
        .object([
            "index": number(item.mark.index),
            "kind": .string(item.mark.kind),
            "wav": .string(item.mark.wav),
            "pass": number(item.mark.pass),
            "startMs": .number(item.mark.startT * 1000),
            "speechMs": .number((item.mark.endT - item.mark.startT) * 1000),
            "speechStoppedMs": optional(item.speechStoppedMs),
            "firstAudioMs": optional(item.firstAudioMs),
            "userTranscript": .string(item.userTranscript),
            "toolCalls": .array(
                item.toolCalls.map {
                    .object([
                        "name": .string($0.name), "arguments": .string($0.arguments), "output": .string($0.output),
                    ])
                }),
            "modelTranscript": .string(item.modelTranscript),
            "audioMs": .number(item.audioMs),
            "runaway": .object([
                "tailAfterDone": .bool(item.tailAfterDone), "overlong": .bool(item.overlong),
                "any": .bool(item.runaway),
            ]),
            "errors": .array(item.errors.map(JSONValue.string)),
        ])
    }

    private func barge(_ item: BargeInResult) -> JSONValue {
        .object([
            "interruptWav": .string(item.interruptWav),
            "bargeInMs": number(item.bargeInMs),
            "interruptStartMs": .number(item.interruptStartMs),
            "speechStartedMs": optional(item.speechStartedMs),
            "lastAudioAfterInterruptMs": optional(item.lastAudioAfterInterruptMs),
            "silenceWithin300Ms": .bool(item.silenceWithin300),
        ])
    }

    private func number(_ value: Int) -> JSONValue { .number(Double(value)) }
    private func optional(_ value: Double?) -> JSONValue { value.map(JSONValue.number) ?? .null }
}
