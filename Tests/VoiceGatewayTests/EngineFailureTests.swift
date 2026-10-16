import Foundation
import SetupKit
import Testing
@testable import VoiceGatewayCore

@Suite(.serialized)
struct EngineFailureTests {
    static let vllmRefusal =
        "ERROR 10-16 19:01:07 [engine.py:81] ValueError: Free memory on device (34.67/95.05 GiB) is less than desired GPU memory utilization (0.4, 38.02 GiB). Decrease GPU memory utilization or reduce GPU memory used by other processes."

    static func log(_ extra: [String] = []) -> String {
        (["INFO starting the speech to speech server", "INFO loading the TTS engine"] + extra + [vllmRefusal, "ERROR the TTS engine failed to start"])
            .joined(separator: "\n") + "\n"
    }

    func died(_ fixture: EngineFixture) async -> LoadSnapshot {
        let engine = fixture.engine
        _ = await fixture.advance(until: { if case .failed = await engine.loadSnapshot() { true } else { false } })
        return await engine.loadSnapshot()
    }

    @Test func theContainerRunsWithTheTwoSharesFromTheSettingsAndNoAutomaticRemoval() async throws {
        let fixture = EngineFixture(llmMemUtil: 0.35, ttsMemUtil: 0.2)
        _ = await fixture.engine.requestStart()
        let run = try #require(fixture.host.runs.first)
        #expect(!run.arguments.contains("--rm"))
        #expect(run.arguments.contains("LLM_GPU_MEM_UTIL=0.35"))
        #expect(run.arguments.contains("TTS_GPU_MEM_UTIL=0.20"))
        let environment = zip(run.arguments, run.arguments.dropFirst()).filter { $0.0 == "-e" }.map(\.1)
        #expect(environment == ["NIM_HTTP_API_PORT=9000", "LLM_GPU_MEM_UTIL=0.35", "TTS_GPU_MEM_UTIL=0.20"])
    }

    @Test func theSharesComeFromTheEnvironmentWithinZeroPointOneAndZeroPointSix() {
        let defaults = GatewayConfig(environment: [:])
        #expect(defaults.llmMemUtil == 0.30 && defaults.ttsMemUtil == 0.25)
        let set = GatewayConfig(environment: ["VOICE_LLM_MEM_UTIL": "0.4", "VOICE_TTS_MEM_UTIL": "0.1"])
        #expect(set.llmMemUtil == 0.4 && set.ttsMemUtil == 0.1)
        let edges = GatewayConfig(environment: ["VOICE_LLM_MEM_UTIL": "0.6", "VOICE_TTS_MEM_UTIL": "0.10"])
        #expect(edges.llmMemUtil == 0.6 && edges.ttsMemUtil == 0.1)
        for bad in ["0.09", "0.61", "1", "0", "-0.3", "lots", ""] {
            let config = GatewayConfig(environment: ["VOICE_LLM_MEM_UTIL": bad, "VOICE_TTS_MEM_UTIL": bad])
            #expect(config.llmMemUtil == 0.30 && config.ttsMemUtil == 0.25, "\(bad)")
        }
    }

    @Test func theNeedsAreTheMeasuredFiftyEightGigabytesPlusMargin() {
        #expect(VoiceRequirements.freeVRAMMB == 62_000)
        #expect(VoiceRequirements.minimumCardMB == 64_000)
    }

    @Test func theLogIsReadBeforeTheContainerIsRemovedAndTheShortfallIsNamed() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        fixture.host.configure {
            $0.machine.container = "exited"
            $0.logs = Self.log()
        }
        guard case .failed(let reason) = await died(fixture) else {
            Issue.record("did not fail")
            return
        }
        #expect(reason == "the GPU did not have the memory the voice engine asked for (35 GB free, 38 GB wanted)")
        let order = fixture.host.calls.filter { $0.executable == "docker" }.compactMap(\.arguments.first)
        let logs = try #require(order.lastIndex(of: "logs"))
        let remove = try #require(order.lastIndex(of: "rm"))
        #expect(logs < remove)
        let logCall = try #require(fixture.host.commands("docker", "logs").last)
        #expect(logCall.arguments == ["logs", "--tail", "60", "nemotron-labs-voicechat"])
        #expect(fixture.host.commands("docker", "rm").last?.arguments == ["rm", "-f", "nemotron-labs-voicechat"])
        #expect(fixture.host.machine.container == nil)

        let failure = try #require(await fixture.engine.recentFailureDetail())
        #expect(failure.id == "gpuMemory")
        #expect(failure.facts["freeMB"] == "35502")
        #expect(failure.facts["needMB"] == "38932")
        let tail = try #require(failure.facts["tail"])
        #expect(tail.contains("less than desired GPU memory utilization"))
        #expect(tail.split(separator: "\n").count <= EngineFailure.tailLines)
        #expect(tail.hasSuffix("ERROR the TTS engine failed to start"))
    }

    @Test func theTailKeepsOnlyTheLastTenLines() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        let noise = (1...50).map { "INFO line \($0)" }
        fixture.host.configure {
            $0.machine.container = "exited"
            $0.logs = Self.log(noise)
        }
        _ = await died(fixture)
        let tail = try #require(await fixture.engine.recentFailureDetail()?.facts["tail"])
        let lines = tail.split(separator: "\n")
        #expect(lines.count == 10)
        #expect(lines.last == "ERROR the TTS engine failed to start")
        #expect(!tail.contains("line 1\n"))
    }

    @Test func aDeathWithoutTheMemoryMessageIsExitedWithItsLog() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        fixture.host.configure {
            $0.machine.container = "exited"
            $0.logs = "INFO starting\nCUDA error: an illegal memory access was encountered\n"
        }
        _ = await died(fixture)
        let failure = try #require(await fixture.engine.recentFailureDetail())
        #expect(failure.id == "exited")
        #expect(failure.facts["tail"] == "INFO starting\nCUDA error: an illegal memory access was encountered")
        #expect(failure.facts["freeMB"] == nil)
    }

    @Test func aMemoryMessageThatCannotBeParsedFallsBackToTheCardsFreeMemory() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        fixture.host.configure {
            $0.machine.container = "exited"
            $0.logs = "ValueError: something is less than desired GPU memory utilization today\n"
        }
        _ = await died(fixture)
        let failure = try #require(await fixture.engine.recentFailureDetail())
        #expect(failure.id == "gpuMemory")
        #expect(failure.facts["freeMB"] == "96687")
        #expect(failure.facts["needMB"] == "62000")
    }

    @Test func aContainerThatIsGoneHasNoLogToReadButStillFails() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        fixture.host.configure { $0.machine.container = nil }
        _ = await died(fixture)
        #expect(fixture.host.commands("docker", "logs").isEmpty)
        let failure = try #require(await fixture.engine.recentFailureDetail())
        #expect(failure.id == "exited")
        #expect(failure.facts["tail"] == nil)
    }

    @Test func aLoadThatNeverFinishesKeepsItsLogBeforeTheContainerIsStoppedAndRemoved() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        fixture.host.configure { $0.logs = "INFO still loading the speech model\n" }
        _ = await died(fixture)
        let failure = try #require(await fixture.engine.recentFailureDetail())
        #expect(failure.id == "notReady")
        #expect(failure.facts["tail"] == "INFO still loading the speech model")
        let order = fixture.host.calls.filter { $0.executable == "docker" }.compactMap(\.arguments.first)
        let logs = try #require(order.lastIndex(of: "logs"))
        let stop = try #require(order.lastIndex(of: "stop"))
        let remove = try #require(order.lastIndex(of: "rm"))
        #expect(logs < stop && stop < remove)
    }

    @Test func aRefusedDockerRunKeepsDockersWordsAsTheTail() async throws {
        let fixture = EngineFixture()
        fixture.host.configure { $0.runFails = "docker: Error response from daemon: port is already allocated." }
        _ = await fixture.engine.requestStart()
        let failure = try #require(await fixture.engine.recentFailureDetail())
        #expect(failure.id == "startFailed")
        #expect(failure.facts["tail"]?.contains("port is already allocated") == true)
    }

    @Test func theIdleStopRemovesTheContainerToo() async {
        var machine = FakeMachine()
        machine.container = "running"
        let fixture = EngineFixture(machine, nim: .ready)
        let engine = fixture.engine
        let monitor = Task { await engine.monitor() }
        defer { monitor.cancel() }
        #expect(await fixture.advance(until: { !fixture.host.stops.isEmpty }, step: 5))
        #expect(await eventually { !fixture.host.commands("docker", "rm").isEmpty })
        #expect(fixture.host.commands("docker", "rm").map(\.arguments) == [["rm", "-f", "nemotron-labs-voicechat"]])
    }

    @Test func theChecklistCarriesTheFailureIdFactsAndTail() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        fixture.host.configure {
            $0.machine.container = "exited"
            $0.logs = Self.log()
        }
        _ = await died(fixture)
        let reading = await fixture.facts.fresh()
        let status = await fixture.engine.derive(reading, managed: true)
        let failure = await fixture.engine.recentFailureDetail()
        let report = Doctor(facts: reading, engine: status, managed: true, jobs: JobsView(), version: "9.9.9", failure: failure).report()
        let engine = try #require(report.checks.first { $0.id == "voice.engine" })
        #expect(engine.state == .blocked)
        #expect(engine.facts["state"] == "down")
        #expect(engine.facts["failure"] == "gpuMemory")
        #expect(engine.facts["freeMB"] == "35502")
        #expect(engine.facts["needMB"] == "38932")
        #expect(engine.facts["tail"]?.contains("less than desired GPU memory utilization") == true)
        let text = DoctorText(unicode: true).render(report)
        #expect(text.contains("Voice engine: did not start, the GPU had 35 GB free and the engine wanted 38 GB for one of its two models"))
        #expect(text.contains("The last lines of its log:"))
    }

    @Test func aFailureIsOnlyReportedWhileItIsFresh() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.requestStart()
        fixture.host.configure { $0.machine.container = "exited" }
        _ = await died(fixture)
        #expect(await fixture.engine.recentFailureDetail() != nil)
        fixture.clock.advance(by: 121)
        #expect(await fixture.engine.recentFailureDetail() == nil)
    }
}
