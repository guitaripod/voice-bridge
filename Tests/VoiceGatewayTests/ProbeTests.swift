import Foundation
import Testing
import VoiceKit
@testable import VoiceGatewayCore

struct WavTests {
    @Test func readsMono24kPCM16() throws {
        let pcm = Tone.pcm(seconds: 0.25)
        let wav = try WavFile.parse(WavFile.encode(pcm), name: "tone.wav")
        #expect(wav.pcm == pcm)
        #expect(abs(wav.seconds - 0.25) < 0.001)
    }

    @Test func skipsUnknownChunksAndTrustsTheFileLengthOverALyingHeader() throws {
        var data = WavFile.encode(Tone.pcm(seconds: 0.1))
        let extra = Data("LIST".utf8) + Data([3, 0, 0, 0, 1, 2, 3, 0])
        data.insert(contentsOf: extra, at: 36)
        let wav = try WavFile.parse(data, name: "x.wav")
        #expect(wav.pcm.count == PCM.bytes(seconds: 0.1))
        var lying = WavFile.encode(Tone.pcm(seconds: 0.1))
        lying.replaceSubrange(40..<44, with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(try WavFile.parse(lying, name: "y.wav").pcm.count == PCM.bytes(seconds: 0.1))
    }

    @Test func rejectsOtherFormatsWithAClearMessage() throws {
        var stereo = WavFile.encode(Tone.pcm(seconds: 0.1))
        stereo.replaceSubrange(22..<24, with: Data([2, 0]))
        var slow = WavFile.encode(Tone.pcm(seconds: 0.1))
        slow.replaceSubrange(24..<28, with: Data([0x44, 0xAC, 0, 0]))
        var floats = WavFile.encode(Tone.pcm(seconds: 0.1))
        floats.replaceSubrange(20..<22, with: Data([3, 0]))
        for (data, needle) in [(stereo, "2 channel"), (slow, "44100 Hz"), (floats, "format tag 3")] {
            do {
                _ = try WavFile.parse(data, name: "bad.wav")
                Issue.record("accepted \(needle)")
            } catch {
                let message = "\(error)"
                #expect(message.contains("bad.wav"))
                #expect(message.contains(needle), "\(message)")
                #expect(message.contains("ffmpeg"))
            }
        }
        #expect(throws: WavError.self) { try WavFile.parse(Data("hello".utf8), name: "t.txt") }
    }
}

struct ProbeAnalysisTests {
    let mark = UtteranceMark(index: 0, kind: "utterance", wav: "a.wav", pass: 0, startT: 1, endT: 2)

    @Test func latencyTranscriptsToolsAndAudioAreAttributed() {
        let events: [TimedEvent] = [
            TimedEvent(t: 2.2, event: .speechStopped),
            TimedEvent(t: 2.3, event: .userTranscriptCompleted(itemID: "a", transcript: " fix it ")),
            TimedEvent(t: 2.4, event: .responseCreated),
            TimedEvent(t: 2.6, event: .audioDelta(Data(count: 48_000))),
            TimedEvent(t: 2.7, event: .transcriptDone("Okay.")),
            TimedEvent(t: 2.8, event: .responseDone(status: "completed")),
        ]
        let tools = [ToolCallRecord(t: 2.45, name: "send_to_agent", arguments: "{}", output: "Sent.")]
        let result = ProbeAnalysis.utterances(events: events, tools: tools, marks: [mark], runEnd: 6, limits: .contract)[0]
        #expect(abs((result.firstAudioMs ?? 0) - 600) < 0.001)
        #expect(abs((result.speechStoppedMs ?? 0) - 200) < 0.001)
        #expect(result.userTranscript == "fix it")
        #expect(result.modelTranscript == "Okay.")
        #expect(result.toolCalls.map(\.name) == ["send_to_agent"])
        #expect(abs(result.audioMs - 1000) < 0.001)
        #expect(!result.runaway)
    }

    @Test func audioMoreThanThreeSecondsAfterDoneIsFlagged() {
        let events: [TimedEvent] = [
            TimedEvent(t: 2.4, event: .responseCreated),
            TimedEvent(t: 2.5, event: .responseDone(status: "completed")),
            TimedEvent(t: 5.6, event: .audioDelta(Data(count: 3_840))),
        ]
        let result = ProbeAnalysis.utterances(events: events, tools: [], marks: [mark], runEnd: 8, limits: .contract)[0]
        #expect(result.tailAfterDone)
        #expect(result.runaway)
    }

    @Test func moreThanTwentyFiveSecondsOfAudioIsFlagged() {
        let events = (0..<7).map { TimedEvent(t: 2.5 + Double($0), event: .audioDelta(Data(count: 4 * PCM.bytesPerSecond))) }
        let result = ProbeAnalysis.utterances(events: events, tools: [], marks: [mark], runEnd: 20, limits: .contract)[0]
        #expect(result.overlong)
    }

    @Test func eachUtteranceOwnsEventsUntilTheNextOne() {
        let second = UtteranceMark(index: 1, kind: "utterance", wav: "b.wav", pass: 0, startT: 5, endT: 6)
        let events: [TimedEvent] = [
            TimedEvent(t: 2.5, event: .audioDelta(Data(count: 4_800))),
            TimedEvent(t: 6.5, event: .audioDelta(Data(count: 9_600))),
        ]
        let results = ProbeAnalysis.utterances(events: events, tools: [], marks: [mark, second], runEnd: 9, limits: .contract)
        #expect(abs(results[0].audioMs - 100) < 0.001)
        #expect(abs(results[1].audioMs - 200) < 0.001)
    }

    @Test func percentilesAreNearestRank() {
        #expect(ProbeAnalysis.percentile([], 0.95) == nil)
        #expect(ProbeAnalysis.percentile([5], 0.95) == 5)
        #expect(ProbeAnalysis.percentile(Array(stride(from: 1.0, through: 100, by: 1)), 0.95) == 95)
        #expect(ProbeAnalysis.percentile([10, 20, 30, 40], 0.5) == 20)
    }
}

@Suite(.serialized)
struct ProbeRunTests {
    func options(_ url: String, wavs: [WavFile]) -> ProbeOptions {
        var options = ProbeOptions(nimURL: url, wavs: wavs)
        options.gapMs = 300
        options.settleMs = 600
        return options
    }

    func tone(_ name: String, seconds: Double = 0.5) -> WavFile {
        WavFile(name: name, pcm: Tone.pcm(seconds: seconds))
    }

    @Test func probeMeasuresAUtteranceAgainstTheDemoNIM() async throws {
        let nim = FakeNIMServer(script: FakeNIMDemo.script)
        await nim.start()
        defer { Task { await nim.stop() } }
        var run = options(nim.url, wavs: [tone("task.wav")])
        run.settleMs = 2_800
        let report = try await ProbeRunner.run(options: run)
        let first = try #require(report.results.first)
        #expect(first.mark.wav == "task.wav")
        #expect(first.userTranscript == "please fix the failing parser test")
        #expect(first.toolCalls.map(\.name) == ["send_to_agent"])
        #expect(first.toolCalls.first?.output == "Sent.")
        #expect(first.modelTranscript == "Okay, on it.")
        #expect((first.firstAudioMs ?? 0) > 0)
        #expect((first.firstAudioMs ?? 99_999) < 3_000)
        #expect(first.audioMs > 2_000)
        #expect(!first.runaway)
        #expect(report.bargeIn == nil)
    }

    @Test func reportJSONHasAStableSchema() async throws {
        let nim = FakeNIMServer(script: FakeNIMDemo.script)
        await nim.start()
        defer { Task { await nim.stop() } }
        let report = try await ProbeRunner.run(options: options(nim.url, wavs: [tone("a.wav", seconds: 0.3)]))
        let json = report.json
        #expect(json["schema"]?.string == "voice-probe/1")
        let object = try #require({ if case .object(let o) = json { o } else { nil } }())
        #expect(Set(object.keys) == ["schema", "nim", "startedAt", "durationSeconds", "options", "utterances", "bargeIn", "recycles", "summary"])
        guard case .array(let rows)? = json["utterances"], case .object(let row)? = rows.first else {
            Issue.record("no utterance rows")
            return
        }
        #expect(
            Set(row.keys) == [
                "index", "kind", "wav", "pass", "startMs", "speechMs", "speechStoppedMs", "firstAudioMs", "userTranscript",
                "toolCalls", "modelTranscript", "audioMs", "runaway", "errors",
            ])
        guard case .object(let summary)? = json["summary"] else {
            Issue.record("no summary")
            return
        }
        #expect(
            Set(summary.keys) == [
                "utterances", "answered", "firstAudioP50Ms", "firstAudioP95Ms", "sendToAgentCalls", "sendToAgentRate", "runaways",
                "modelErrors", "recycles",
            ])
        #expect(JSONValue.parse(report.pretty()) == json)
    }

    @Test func bargeInReportsHowFastTheModelWentQuiet() async throws {
        let nim = FakeNIMServer(script: FakeNIMDemo.script)
        await nim.start()
        defer { Task { await nim.stop() } }
        var run = options(nim.url, wavs: [tone("task.wav")])
        run.bargeInMs = 300
        run.interruptWav = tone("interrupt.wav", seconds: 0.6)
        run.gapMs = 800
        run.settleMs = 800
        let report = try await ProbeRunner.run(options: run)
        let barge = try #require(report.bargeIn)
        #expect(barge.interruptWav == "interrupt.wav")
        #expect(report.results.map(\.mark.kind) == ["utterance", "interrupt"])
        #expect(barge.speechStartedMs != nil)
        #expect((barge.lastAudioAfterInterruptMs ?? 0) < 1_500)
        #expect(report.json["bargeIn"]?["silenceWithin300Ms"] != nil)
    }

    @Test func aRunawayModelIsFlagged() async throws {
        let nim = FakeNIMServer { session in
            _ = await session.waitForAudio(bytes: 20_000)
            await session.emit(.speechStopped)
            await session.emit(.responseCreated)
            for _ in 0..<8 { await session.emit(.audio(Data(count: 4 * PCM.bytesPerSecond))) }
            await session.emit(.responseDone(status: "completed"))
        }
        await nim.start()
        defer { Task { await nim.stop() } }
        let report = try await ProbeRunner.run(options: options(nim.url, wavs: [tone("a.wav", seconds: 0.5)]))
        #expect(report.results.first?.overlong == true)
        #expect(report.summary["runaways"]?.number == 1)
    }

    @Test func soakRecyclesOnTheSamePolicy() async throws {
        let nim = FakeNIMServer()
        await nim.start()
        defer { Task { await nim.stop() } }
        var limits = GatewayLimits.contract
        limits.recycleAudioSeconds = 0.5
        var run = options(nim.url, wavs: [tone("a.wav", seconds: 0.4)])
        run.soakSeconds = 2
        run.gapMs = 600
        run.settleMs = 100
        let report = try await ProbeRunner.run(options: run, limits: limits)
        #expect(report.recycles.count >= 1)
        #expect(nim.sessions.count == report.recycles.count + 1)
        #expect(report.spoken.count >= 2)
        #expect((report.spoken.map(\.mark.pass).max() ?? 0) >= 1)
        #expect(report.recycles.allSatisfy { $0.reopenMs < 2_000 })
    }

    @Test func unreachableNIMIsAClearError() async {
        await #expect(throws: ProbeError.self) {
            _ = try await ProbeRunner.run(options: ProbeOptions(nimURL: "ws://127.0.0.1:1/v1/realtime", wavs: [WavFile(name: "a.wav", pcm: Tone.pcm(seconds: 0.2))]))
        }
    }
}

struct ProbeCLITests {
    @Test func argumentErrorsAreCaught() async {
        #expect(await ProbeCLI.main([]) == 2)
        #expect(await ProbeCLI.main(["run"]) == 2)
        #expect(await ProbeCLI.main(["run", "--wav", "/nonexistent.wav"]) == 2)
        #expect(await ProbeCLI.main(["bogus"]) == 2)
    }

    @Test func bargeInFlagsGoTogether() throws {
        let path = NSTemporaryDirectory() + "probe-cli-\(UUID().uuidString).wav"
        try WavFile.encode(Tone.pcm(seconds: 0.1)).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) { try ProbeCLI.options(["--wav", path, "--barge-in-ms", "200"]) }
        let (options, json) = try ProbeCLI.options(["--wav", path, "--gap-ms", "10", "--json", "out.json", "--nim", "ws://h:1/x"])
        #expect(options.gapMs == 10)
        #expect(options.nimURL == "ws://h:1/x")
        #expect(json == "out.json")
    }
}
