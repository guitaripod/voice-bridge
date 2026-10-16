import Foundation
import SetupKit
import Testing
@testable import VoiceGatewayCore

@Suite(.serialized)
struct SetupJobsTests {
    static let writeModel = """
        dest=""; while [ $# -gt 0 ]; do [ "$1" = "--dest" ] && dest="$2"; shift; done
        weights="$dest/nemotron-labs-voicechat_v1.0.0/nemotron-voicechat/1"
        mkdir -p "$weights"
        """

    static func ngcScript(waitFor gate: String? = nil, harness: JobHarness) -> String {
        let hold = gate.map { "while [ ! -e '\(harness.bin.url.path)/\($0)' ]; do sleep 0.05; done" } ?? ""
        return """
            \(writeModel)
            truncate -s 20000000000 "$weights/perception.safetensors"
            echo "Downloaded 20 GB"
            \(hold)
            truncate -s 46868000000 "$weights/perception.safetensors"
            echo 'name: "nemotron-voicechat"' > "$dest/nemotron-labs-voicechat_v1.0.0/nemotron-voicechat/config.pbtxt"
            echo done
            """
    }

    @Test func theModelDownloadReportsBytesOnDiskAndEndsWithAValidModel() async throws {
        let harness = JobHarness()
        harness.installNGC(Self.ngcScript(waitFor: "go", harness: harness))
        let started = try await harness.jobs.start(fix: "voice.downloadModel")
        #expect(started.state == .running)
        #expect(started.fix == "voice.downloadModel")

        let midway = await harness.waitFor(started.id) { ($0.bytesDone ?? 0) >= 20_000_000_000 }
        #expect(midway?.state == .running)
        #expect(midway?.step == "download")
        #expect(midway?.bytesTotal == 46_868_000_000)
        let fraction = try #require(midway?.fraction)
        #expect(fraction > 0.4 && fraction < 0.45)
        #expect(await harness.jobs.hasOpenJob)
        #expect(await harness.jobs.view().open["voice.downloadModel"]?.id == started.id)

        harness.release("go")
        let done = await harness.settle(started)
        #expect(done?.state == .succeeded)
        #expect(done?.fraction == 1)
        #expect(done?.failure == nil)
        #expect(ModelDirectory.inspect(harness.root.paths.modelDir).valid)
        #expect(harness.ngcArgs == "registry model download-version nim/nvidia/nemotron-labs-voicechat:1.0.0 --dest \(harness.root.paths.modelDir.path)\n")
        let config = harness.root.paths.modelDir.appendingPathComponent("nemotron-labs-voicechat_v1.0.0/nemotron-voicechat/config.pbtxt")
        let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int ?? 0
        #expect(mode & 0o006 == 0o006)
        #expect(await harness.jobs.hasOpenJob == false)
    }

    @Test func aModelAlreadyThereIsAJobThatDoesNothing() async throws {
        let harness = JobHarness(model: .complete)
        harness.installNGC("echo should not run > '\(harness.bin.url.path)/ran'")
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        #expect(await harness.settle(job)?.state == .succeeded)
        #expect(harness.ngcArgs == nil)
    }

    @Test func notEnoughDiskIsRefusedBeforeAnythingStarts() async throws {
        let harness = JobHarness(freeDiskMB: 9_000)
        harness.installNGC(Self.ngcScript(harness: harness))
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        let done = await harness.settle(job)
        #expect(done?.state == .failed)
        #expect(done?.failure == "noDisk")
        #expect(done?.facts["needMB"] == "46868")
        #expect(done?.facts["freeMB"] == "9000")
        #expect(harness.ngcArgs == nil)
    }

    @Test func aPartialModelOnlyNeedsWhatIsMissing() async throws {
        let harness = JobHarness(freeDiskMB: 20_000, model: .partial(35_000_000_000))
        harness.installNGC(Self.ngcScript(harness: harness))
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        #expect(await harness.settle(job)?.state == .succeeded)
    }

    @Test(arguments: [
        ("echo 'ConnectionError: Connection timed out' >&2; exit 1", "network"),
        ("echo 'Error: 401 Unauthorized: invalid or missing API key' >&2; exit 1", "denied"),
        ("echo 'something odd happened' >&2; exit 1", "other"),
    ])
    func aFailedDownloadIsOneOfTheFailureIdsWithTheToolsLastLines(output: String, expected: String) async throws {
        let harness = JobHarness()
        harness.installNGC("echo 'starting download'\n\(output)")
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        let done = await harness.settle(job)
        #expect(done?.state == .failed)
        #expect(done?.failure == expected)
        #expect(done?.facts["tail"]?.contains("starting download") == true)
        let view = await harness.jobs.view()
        #expect(view.lastFailed["voice.downloadModel"]?.id == job.id)
        #expect(view.open.isEmpty)
    }

    @Test func aToolThatRunsOutOfSpaceReportsWhatWasNeeded() async throws {
        let harness = JobHarness()
        harness.installNGC("echo 'OSError: [Errno 28] No space left on device' >&2; exit 1")
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        let done = await harness.settle(job)
        #expect(done?.failure == "noDisk")
        #expect(done?.facts["freeMB"] == "500000")
        #expect(done?.facts["needMB"] == "46868")
    }

    @Test func cancelKillsTheProcessGroupKeepsPartialFilesAndTheNextRunResumes() async throws {
        let harness = JobHarness()
        let pidFile = harness.bin.url.appendingPathComponent("child.pid")
        harness.installNGC(
            """
            \(Self.writeModel)
            if [ -e "$weights/perception.safetensors" ]; then echo resumed > '\(harness.bin.url.path)/resumed'; fi
            truncate -s 15000000000 "$weights/perception.safetensors"
            if [ ! -e '\(harness.bin.url.path)/resumed' ]; then
              sleep 60 &
              echo $! > '\(pidFile.path)'
              wait
            fi
            truncate -s 46868000000 "$weights/perception.safetensors"
            echo 'name: "nemotron-voicechat"' > "$dest/nemotron-labs-voicechat_v1.0.0/nemotron-voicechat/config.pbtxt"
            """)
        let first = try await harness.jobs.start(fix: "voice.downloadModel")
        #expect(await harness.waitFor(first.id) { ($0.bytesDone ?? 0) >= 15_000_000_000 } != nil)
        let child = try #require(Int32(String(contentsOfFile: pidFile.path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(child, 0) == 0)

        let cancelled = await harness.jobs.cancel(first.id)
        #expect(cancelled?.state == .cancelled)
        #expect(await eventually { kill(child, 0) != 0 })
        #expect(ModelDirectory.inspect(harness.root.paths.modelDir).bytes == 15_000_000_000)
        #expect(await harness.jobs.view().open.isEmpty)
        #expect(await harness.jobs.view().lastFailed.isEmpty)

        let second = try await harness.jobs.start(fix: "voice.downloadModel")
        #expect(second.id != first.id)
        #expect(await harness.settle(second)?.state == .succeeded)
        #expect(FileManager.default.fileExists(atPath: harness.bin.url.appendingPathComponent("resumed").path))
    }

    @Test func aFixThatIsAlreadyRunningIsRefusedWithTheRunningJob() async throws {
        let harness = JobHarness()
        harness.installNGC(Self.ngcScript(waitFor: "go", harness: harness))
        let first = try await harness.jobs.start(fix: "voice.downloadModel")
        await #expect(throws: SetupJobError.self) { _ = try await harness.jobs.start(fix: "voice.downloadModel") }
        do { _ = try await harness.jobs.start(fix: "voice.downloadModel") } catch let error as SetupJobError {
            if case .alreadyRunning(let running) = error { #expect(running.id == first.id) } else { Issue.record("wrong error \(error)") }
        }
        harness.release("go")
        #expect(await harness.settle(first)?.state == .succeeded)
        _ = try await harness.jobs.start(fix: "voice.downloadModel")
    }

    @Test func anUnknownFixIsRefused() async {
        let harness = JobHarness()
        do {
            _ = try await harness.jobs.start(fix: "voice.format-the-disk")
            Issue.record("should have thrown")
        } catch {
            #expect(error as? SetupJobError == .unknownFix)
        }
    }

    @Test func aMachineThatCannotRunVoiceStartsNothing() async {
        let harness = JobHarness(gpuTotalMB: 49_140)
        harness.installNGC(Self.ngcScript(harness: harness))
        do {
            _ = try await harness.jobs.start(fix: "voice.downloadModel")
            Issue.record("should have thrown")
        } catch {
            #expect(error as? SetupJobError == .unsupported)
        }
        #expect(harness.ngcArgs == nil)
    }

    @Test func aRestartFindsFinishedJobsAndFailsTheOnesThatWereRunning() async throws {
        let harness = JobHarness()
        harness.installNGC("echo 'oops' >&2; exit 1")
        let failed = try await harness.jobs.start(fix: "voice.downloadModel")
        #expect(await harness.settle(failed)?.state == .failed)
        harness.store.save(SetupJob(id: "job-was-running", fix: "voice.pullImage", state: .running, step: "pull", fraction: 0.4, startedAt: 99))

        let reopened = harness.reopen()
        #expect(await reopened.job(failed.id)?.failure == "other")
        let interrupted = await reopened.job("job-was-running")
        #expect(interrupted?.state == .failed)
        #expect(interrupted?.failure == "interrupted")
        #expect(interrupted?.fraction == 0.4)
        #expect(await reopened.hasOpenJob == false)
        #expect(await reopened.view().lastFailed["voice.pullImage"]?.failure == "interrupted")
        let again = harness.reopen()
        #expect(await again.job("job-was-running")?.failure == "interrupted")
    }

    @Test func onlyTheNewestJobsAreKept() async throws {
        let harness = JobHarness()
        for index in 0..<(JobStore.keep + 5) {
            harness.store.save(SetupJob(id: "old-\(index)", fix: "voice.pullImage", state: .succeeded, startedAt: Double(index)))
        }
        let reopened = harness.reopen()
        #expect(await reopened.job("old-0") == nil)
        #expect(await reopened.job("old-\(JobStore.keep + 4)") != nil)
        #expect(harness.store.loadAll().count == JobStore.keep)
    }
}
