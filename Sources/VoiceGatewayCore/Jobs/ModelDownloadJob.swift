import Foundation

/// `voice.downloadModel`: make sure the NGC CLI is there, download the model next to whatever of it is
/// already on disk, open the permissions the NIM wants, and check the result.
struct ModelDownloadJob: Sendable {
    let environment: JobEnvironment

    private var directory: URL { environment.paths.modelDir }

    func run(_ context: JobContext) async -> JobResult {
        let present = ModelDirectory.inspect(directory)
        if present.valid { return .succeeded }
        await context.progress(step: "disk")
        if let failure = await diskFailure(remaining: max(0, VoiceRequirements.modelBytes - present.bytes)) { return .failed(failure) }
        if context.isCancelled { return .cancelled }
        let ngc: String
        switch await NGCInstaller(environment: environment).ensure(context) {
        case .success(let path): ngc = path
        case .failure(let failure): return .failed(failure)
        }
        if context.isCancelled { return .cancelled }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let failure = await download(ngc, context) { return .failed(failure) }
        if context.isCancelled { return .cancelled }
        await context.progress(step: "permissions", fraction: 0.99)
        let root = ModelDirectory.inspect(directory).root
        let chmod = await environment.runner.run(CommandSpec("chmod", ["-R", "a+rwX", root.path], timeout: 600))
        guard chmod.succeeded else { return .failed(.other("chmod", tail: chmod.tail(4))) }
        let after = ModelDirectory.inspect(directory)
        guard after.valid else {
            return .failed(JobFailure(id: JobFailure.other, facts: ["reason": "incomplete", "bytes": "\(after.bytes)", "needBytes": "\(VoiceRequirements.modelBytes)"]))
        }
        await context.progress(step: "done", fraction: 1, bytesDone: after.bytes, bytesTotal: VoiceRequirements.modelBytes)
        return .succeeded
    }

    private func diskFailure(remaining: Int64) async -> JobFailure? {
        guard let free = await DiskSpace.freeMB(at: directory, runner: environment.runner) else { return nil }
        let need = Int(remaining / 1_000_000)
        return free < need ? .noDisk(needMB: need, freeMB: free) : nil
    }

    private func download(_ ngc: String, _ context: JobContext) async -> JobFailure? {
        await context.progress(step: "download", fraction: 0, bytesDone: ModelDirectory.inspect(directory).bytes, bytesTotal: VoiceRequirements.modelBytes)
        let spec = CommandSpec(
            ngc, ["registry", "model", "download-version", VoiceRequirements.modelReference, "--dest", directory.path],
            environment: environment.ngcEnvironment)
        let watcher = Task { await watch(context) }
        var tail = OutputTail()
        let result = await context.stream(environment.runner, spec) { tail.add($0) }
        watcher.cancel()
        if context.isCancelled || result.succeeded { return nil }
        guard result.launched else { return .other("ngcNotLaunched", tail: [result.error]) }
        var failure = JobFailure(id: FailureClassifier.classify(tail.lines), facts: JobFailure.tailFacts(tail.lines))
        if failure.id == JobFailure.noDisk, let free = await DiskSpace.freeMB(at: directory, runner: environment.runner) {
            failure.facts.merge(["needMB": "\(VoiceRequirements.modelBytes / 1_000_000)", "freeMB": "\(free)"]) { _, new in new }
        }
        return failure
    }

    /// NGC prints no byte counts we can rely on, so progress is what has landed on disk against the known size.
    private func watch(_ context: JobContext) async {
        var next = environment.clock.now() + environment.pollSeconds
        while !Task.isCancelled {
            do { try await environment.clock.sleep(until: next) } catch { return }
            let directory = self.directory
            let bytes = await Task.detached { ModelDirectory.inspect(directory).bytes }.value
            let fraction = min(0.98, Double(bytes) / Double(VoiceRequirements.modelBytes))
            await context.progress(step: "download", fraction: fraction, bytesDone: bytes, bytesTotal: VoiceRequirements.modelBytes)
            next = environment.clock.now() + environment.pollSeconds
        }
    }
}
