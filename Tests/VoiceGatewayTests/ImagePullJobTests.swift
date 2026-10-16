import Foundation
import SetupKit
import Testing
@testable import VoiceGatewayCore

@Suite(.serialized)
struct ImagePullJobTests {
    static func layers(gate: String, harness: JobHarness) -> String {
        """
        echo 'latest: Pulling from nim/nvidia/nemotron-labs-voicechat'
        for id in aaaaaaaaaaaa bbbbbbbbbbbb cccccccccccc dddddddddddd; do echo "$id: Pulling fs layer"; done
        echo 'aaaaaaaaaaaa: Already exists'
        echo 'bbbbbbbbbbbb: Downloading [==>   ] 1MB/10MB'
        echo 'bbbbbbbbbbbb: Pull complete'
        while [ ! -e '\(harness.bin.url.path)/\(gate)' ]; do sleep 0.05; done
        echo 'cccccccccccc: Pull complete'
        echo 'dddddddddddd: Pull complete'
        touch '\(harness.bin.url.path)/image-present'
        echo 'Status: Downloaded newer image'
        """
    }

    @Test func progressIsTheShareOfLayersFinished() async throws {
        let harness = JobHarness()
        harness.installDocker(pull: Self.layers(gate: "go", harness: harness))
        let job = try await harness.jobs.start(fix: "voice.pullImage")
        let midway = await harness.waitFor(job.id) { ($0.fraction ?? 0) >= 0.5 }
        #expect(midway?.fraction == 0.5)
        #expect(midway?.state == .running)
        #expect(midway?.step == "pull")
        #expect(midway?.bytesTotal == 22_500_000_000)
        #expect(midway?.bytesDone == nil)
        harness.release("go")
        let done = await harness.settle(job)
        #expect(done?.state == .succeeded)
        #expect(done?.fraction == 1)
        let pull = try String(contentsOf: harness.bin.url.appendingPathComponent("docker.pull"), encoding: .utf8)
        #expect(pull == "pull nvcr.io/nim/nvidia/nemotron-labs-voicechat:latest\n")
    }

    @Test func anImageThatIsThereIsNotPulledAgain() async throws {
        let harness = JobHarness()
        harness.installDocker(image: true, pull: "exit 1")
        let job = try await harness.jobs.start(fix: "voice.pullImage")
        #expect(await harness.settle(job)?.state == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: harness.bin.url.appendingPathComponent("docker.pull").path))
    }

    @Test func notEnoughRoomForTheImageIsRefusedBeforeThePull() async throws {
        let harness = JobHarness(freeDiskMB: 10_000)
        harness.installDocker(pull: "echo pulled")
        let job = try await harness.jobs.start(fix: "voice.pullImage")
        let done = await harness.settle(job)
        #expect(done?.failure == "noDisk")
        #expect(done?.facts["needMB"] == "22500")
        #expect(done?.facts["freeMB"] == "10000")
        #expect(!FileManager.default.fileExists(atPath: harness.bin.url.appendingPathComponent("docker.pull").path))
    }

    @Test(arguments: [
        ("denied: requested access to the resource is denied", "denied"),
        ("Error response from daemon: unauthorized: authentication required", "denied"),
        ("Error response from daemon: Get \"https://nvcr.io/v2/\": net/http: TLS handshake timeout", "network"),
        ("write /var/lib/docker/tmp/x: no space left on device", "noDisk"),
        ("Error response from daemon: manifest unknown", "other"),
    ])
    func failuresAreIdsWithTheToolsLastLines(line: String, expected: String) async throws {
        let harness = JobHarness()
        harness.installDocker(pull: "echo 'aaaaaaaaaaaa: Pulling fs layer'\necho '\(line)' >&2\nexit 1")
        let job = try await harness.jobs.start(fix: "voice.pullImage")
        let done = await harness.settle(job)
        #expect(done?.state == .failed)
        #expect(done?.failure == expected)
        #expect(done?.facts["tail"]?.contains("Pulling fs layer") == true)
        #expect(done?.facts["tail"]?.contains(line) == true)
    }

    @Test func cancellingAPullKeepsWhatHasBeenPulled() async throws {
        let harness = JobHarness()
        harness.installDocker(pull: "echo 'aaaaaaaaaaaa: Pulling fs layer'\nsleep 60")
        let job = try await harness.jobs.start(fix: "voice.pullImage")
        #expect(await harness.waitFor(job.id) { $0.step == "pull" } != nil)
        try await Task.sleep(for: .milliseconds(200))
        let cancelled = await harness.jobs.cancel(job.id)
        #expect(cancelled?.state == .cancelled)
        #expect(await harness.jobs.view().open.isEmpty)
    }

    @Test func layerLinesAreParsedLeniently() {
        var progress = PullProgress()
        for line in ["latest: Pulling from x", "Digest: sha256:abc", "not a layer: Pull complete", "abc: Pull complete"] { progress.feed(line) }
        #expect(progress.fraction == nil)
        progress.feed("0123456789ab: Pulling fs layer")
        progress.feed("0123456789ab: Pull complete")
        #expect(progress.fraction == 0.99)
    }
}
