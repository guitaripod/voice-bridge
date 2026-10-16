import Foundation

/// `voice.pullImage`: `docker pull` of the NIM image with progress from its layer lines.
struct ImagePullJob: Sendable {
    let environment: JobEnvironment

    func run(_ context: JobContext) async -> JobResult {
        let runner = environment.runner
        if await environment.probe.imageBytes() != nil { return .succeeded }
        await context.progress(step: "disk")
        if let failure = await diskFailure() { return .failed(failure) }
        if context.isCancelled { return .cancelled }
        await context.progress(step: "pull", fraction: 0, bytesTotal: VoiceRequirements.imageBytes)
        var progress = PullProgress()
        var tail = OutputTail()
        let result = await context.stream(runner, CommandSpec("docker", ["pull", VoiceRequirements.imageName])) { line in
            tail.add(line)
            let before = progress.fraction
            progress.feed(line)
            if progress.fraction != before {
                await context.progress(step: "pull", fraction: progress.fraction, bytesTotal: VoiceRequirements.imageBytes)
            }
        }
        if context.isCancelled { return .cancelled }
        if result.succeeded {
            await context.progress(step: "done", fraction: 1, bytesTotal: VoiceRequirements.imageBytes)
            return .succeeded
        }
        guard result.launched else { return .failed(.other("dockerNotLaunched", tail: [result.error])) }
        var failure = JobFailure(id: FailureClassifier.classify(tail.lines), facts: JobFailure.tailFacts(tail.lines))
        if failure.id == JobFailure.noDisk, let free = await dockerFreeMB() {
            failure.facts.merge(["needMB": "\(VoiceRequirements.imageBytes / 1_000_000)", "freeMB": "\(free)"]) { _, new in new }
        }
        return .failed(failure)
    }

    private func diskFailure() async -> JobFailure? {
        guard let free = await dockerFreeMB() else { return nil }
        let need = Int(VoiceRequirements.imageBytes / 1_000_000)
        return free < need ? .noDisk(needMB: need, freeMB: free) : nil
    }

    private func dockerFreeMB() async -> Int? {
        let info = await environment.runner.run(CommandSpec("docker", ["info", "--format", "{{.DockerRootDir}}"], timeout: 15))
        let root = info.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard info.succeeded, root.hasPrefix("/") else { return nil }
        return await DiskSpace.freeMB(at: URL(fileURLWithPath: root), runner: environment.runner)
    }
}
