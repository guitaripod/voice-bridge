import Foundation
import Testing
@testable import VoiceGatewayCore

@Suite(.serialized)
struct ProbePromptTests {
    static func file(_ text: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    static func wav() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).wav")
        var data = Data("RIFF".utf8)
        let pcm = Tone.pcm(seconds: 0.2)
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        data += le32(36 + pcm.count) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(24_000) + le32(48_000) + le16(2) + le16(16)
        data += Data("data".utf8) + le32(pcm.count) + pcm
        try? data.write(to: url)
        return url.path
    }

    func parse(_ extra: [String]) throws -> (ProbeOptions, String?) {
        try ProbeCLI.options(["--wav", Self.wav()] + extra)
    }

    @Test func theDefaultsAreTheSpeakingPersonaAndTheThreeTools() throws {
        let (options, _) = try parse([])
        #expect(options.instructions == VoiceTools.systemPrompt)
        #expect(options.tools == VoiceTools.all)
        #expect(!options.summaryTable)
    }

    @Test func instructionsComeFromAFileTrimmed() throws {
        let (options, _) = try parse(["--instructions", Self.file("  Only listen.\n\n")])
        #expect(options.instructions == "Only listen.")
        #expect(options.tools == VoiceTools.all)
    }

    @Test func anUnreadableOrEmptyInstructionsFileIsAUsageError() {
        #expect(throws: ProbeCLI.UsageError.self) { try parse(["--instructions", "/nonexistent/prompt.txt"]) }
        #expect(throws: ProbeCLI.UsageError.self) { try parse(["--instructions", Self.file(" \n")]) }
    }

    @Test func noToolsRegistersNone() throws {
        let (options, _) = try parse(["--no-tools", "--summary-table"])
        #expect(options.tools.isEmpty)
        #expect(options.summaryTable)
    }

    @Test func toolsComeFromAJsonFileInTheNIMsShape() throws {
        let json = """
            [{"type":"function","name":"send_to_agent","description":"Send it.","ack_messages":["Sending."],
              "parameters":{"type":"object","properties":{"task":{"type":"string"}},"required":["task"]}},
             {"type":"function","name":"stop_agent"}]
            """
        let (options, _) = try parse(["--tools-json", Self.file(json)])
        #expect(options.tools.map(\.name) == ["send_to_agent", "stop_agent"])
        #expect(options.tools[0].ackMessages == ["Sending."])
        #expect(options.tools[0].parameters["required"] != nil)
        #expect(options.tools[1].description == "")
        #expect(options.tools[1].parameters["type"]?.string == "object")
    }

    @Test func badToolsFilesAndConflictingFlagsAreUsageErrors() {
        #expect(throws: (any Error).self) { try parse(["--tools-json", Self.file("{\"name\":\"x\"}")]) }
        #expect(throws: (any Error).self) { try parse(["--tools-json", Self.file("[{\"description\":\"no name\"}]")]) }
        #expect(throws: (any Error).self) { try parse(["--tools-json", "/nonexistent/tools.json"]) }
        #expect(throws: ProbeCLI.UsageError.self) { try parse(["--no-tools", "--tools-json", Self.file("[]")]) }
    }

    @Test func aFlagIsNotSwallowedAsAValue() {
        #expect(throws: ProbeCLI.UsageError.self) { try parse(["--instructions"]) }
        #expect(throws: ProbeCLI.UsageError.self) { try parse(["--no-tools-please"]) }
    }

    @Test func theSessionOpensWithTheGivenInstructionsAndNoTools() async throws {
        let nim = FakeNIMServer()
        await nim.start()
        defer { Task { await nim.stop() } }
        var run = ProbeOptions(nimURL: nim.url, wavs: [WavFile(name: "a.wav", pcm: Tone.pcm(seconds: 0.2))])
        run.instructions = "Only listen."
        run.tools = []
        run.settleMs = 100
        _ = try await ProbeRunner.run(options: run)
        let session = try #require(nim.sessions.first)
        let update = try #require(await session.message("session.update"))
        #expect(update.json["session"]?["instructions"]?.string == "Only listen.")
        #expect(update.json["session"]?["tools"] == nil)
    }

    @Test func theSummaryTableIsOnePlainRowPerUtteranceAndTheTotals() async throws {
        let nim = FakeNIMServer(script: FakeNIMDemo.script)
        await nim.start()
        defer { Task { await nim.stop() } }
        var run = ProbeOptions(nimURL: nim.url, wavs: [WavFile(name: "task.wav", pcm: Tone.pcm(seconds: 0.5))])
        run.settleMs = 2_800
        let report = try await ProbeRunner.run(options: run)
        let table = report.summaryTable()
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0].hasPrefix("#  wav       first audio  tools"))
        #expect(lines[1].hasPrefix("0  task.wav"))
        #expect(lines[1].contains("send_to_agent"))
        #expect(lines[1].contains("please fix the failing parser test"))
        #expect(table.contains("send_to_agent 1/1"))
        #expect(table.contains("utterances 1, answered 1, first audio p50"))
        #expect(table.utf8.allSatisfy { $0 < 0x80 })
    }

    @Test func theSummaryTableHandlesSilenceAndLongText() {
        let mark = UtteranceMark(index: 0, kind: "utterance", wav: "u1.wav", pass: 0, startT: 0, endT: 1)
        let quiet = UtteranceResult(
            mark: mark, speechStoppedMs: nil, firstAudioMs: nil, userTranscript: String(repeating: "word ", count: 30), toolCalls: [],
            modelTranscript: "", audioMs: 0, tailAfterDone: false, overlong: false, errors: [])
        let report = ProbeReport(
            nim: "ws://x", startedAt: Date(), durationSeconds: 1, gapMs: 0, settleMs: 0, soakSeconds: nil, results: [quiet],
            bargeIn: nil, recycles: [])
        let table = report.summaryTable()
        #expect(table.contains("u1.wav  -"))
        #expect(table.contains("~"))
        #expect(table.contains("first audio p50 n/a p95 n/a, send_to_agent 0/1"))
    }
}
