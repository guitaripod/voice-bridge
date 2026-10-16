import Foundation
import SetupKit
import Testing
@testable import VoiceGatewayCore

/// Real processes, fake machine: executables in a temporary `PATH`, a temporary home, a manual clock.
final class JobHarness: Sendable {
    let bin = FakeBin()
    let root: FakeRoot
    let clock = ManualClock()
    let runner: ProcessRunner
    let environment: JobEnvironment
    let jobs: SetupJobs
    let store: JobStore

    init(
        gpuTotalMB: Int = 97_887, freeDiskMB: Int = 500_000, model: FakeMachine.ModelShape = .absent,
        gatewayEnvironment: [String: String] = [:], ngcPackage: @escaping @Sendable (String) -> NGCRelease.Package? = NGCRelease.package(machine:)
    ) {
        root = FakeRoot(FakeMachine(model: model))
        bin.install("nvidia-smi", "case \"$1\" in --query-gpu*) echo \"Test GPU, \(gpuTotalMB), 1000\";; *) ;; esac")
        bin.install("df", "echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'; echo \"/dev/x 9 1 $(( $(cat '\(bin.url.path)/free_mb') * 1024 )) 1% /\"")
        runner = bin.runner()
        let probe = MachineProbe(runner: runner, paths: root.paths, nim: FakeNIMProbe())
        environment = JobEnvironment(
            runner: runner, probe: probe, paths: root.paths, clock: clock, gatewayEnvironment: gatewayEnvironment, ngcPackage: ngcPackage)
        store = JobStore(directory: root.paths.jobsDir)
        jobs = JobHarness.makeJobs(environment: environment, store: store)
        setFreeDisk(freeDiskMB)
    }

    static func makeJobs(environment: JobEnvironment, store: JobStore) -> SetupJobs {
        SetupJobs(
            store: store,
            works: [
                VoiceRequirements.downloadModelFix: ModelDownloadJob(environment: environment),
                VoiceRequirements.pullImageFix: ImagePullJob(environment: environment),
            ],
            probe: environment.probe)
    }

    func reopen() -> SetupJobs {
        JobHarness.makeJobs(environment: environment, store: store)
    }

    func setFreeDisk(_ mb: Int) {
        try? "\(mb)".write(to: bin.url.appendingPathComponent("free_mb"), atomically: true, encoding: .utf8)
    }

    func installNGC(_ body: String) {
        bin.install("ngc", "case \"$1\" in --version) echo 'NGC CLI 4.34.10'; exit 0;; esac\necho \"$@\" > '\(bin.url.path)/ngc.args'\n\(body)")
    }

    func installDocker(image: Bool = false, pull: String) {
        let marker = bin.url.appendingPathComponent("image-present")
        if image { FileManager.default.createFile(atPath: marker.path, contents: nil) }
        bin.install(
            "docker",
            """
            case "$1" in
              info) echo /;;
              image) if [ -e '\(marker.path)' ]; then echo 22543587937; else echo 'Error: No such image' >&2; exit 1; fi;;
              pull) echo "$@" > '\(bin.url.path)/docker.pull'
                \(pull)
                ;;
              *) exit 1;;
            esac
            """)
    }

    var ngcArgs: String? { try? String(contentsOf: bin.url.appendingPathComponent("ngc.args"), encoding: .utf8) }

    func release(_ name: String) {
        FileManager.default.createFile(atPath: bin.url.appendingPathComponent(name).path, contents: nil)
    }

    func waitFor(_ id: String, in jobs: SetupJobs? = nil, timeout: Double = 8, _ condition: @Sendable @escaping (SetupJob) -> Bool) async -> SetupJob? {
        let target = jobs ?? self.jobs
        let clock = self.clock
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let job = await target.job(id), condition(job) { return job }
            clock.advance(by: 1)
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await target.job(id)
    }

    func settle(_ job: SetupJob) async -> SetupJob? {
        await waitFor(job.id) { $0.state.isSettled }
    }
}
