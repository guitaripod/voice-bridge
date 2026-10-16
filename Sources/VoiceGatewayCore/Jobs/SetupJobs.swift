import Foundation
import Logging
import SetupKit

protocol SetupJobWork: Sendable {
    func run(_ context: JobContext) async -> JobResult
}

extension ModelDownloadJob: SetupJobWork {}
extension ImagePullJob: SetupJobWork {}

enum SetupJobError: Error, Equatable {
    case unknownFix
    case alreadyRunning(SetupJob)
    case unsupported
}

/// The long jobs the checklist offers: started by a fix, followed by id, cancelled by id, and kept on
/// disk so a gateway that restarts still knows them. A job that was running when the gateway stopped
/// reads as failed with `interrupted`; running its fix again picks the work up where the files stand.
actor SetupJobs {
    private var jobs: [String: SetupJob] = [:]
    private var contexts: [String: JobContext] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let store: JobStore
    private let works: [String: any SetupJobWork]
    private let probe: MachineProbe
    private let wall: @Sendable () -> Double
    private let logger: Logger

    init(
        store: JobStore, works: [String: any SetupJobWork], probe: MachineProbe,
        wall: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }, logger: Logger = Logger(label: "voice.jobs")
    ) {
        self.store = store
        self.works = works
        self.probe = probe
        self.wall = wall
        self.logger = logger
        var loaded: [String: SetupJob] = [:]
        for var job in store.loadAll() {
            if !job.state.isSettled {
                job.state = .failed
                job.failure = JobFailure.interrupted
                store.save(job)
            }
            loaded[job.id] = job
        }
        jobs = Dictionary(uniqueKeysWithValues: store.prune(Array(loaded.values)).map { ($0.id, $0) })
    }

    var hasOpenJob: Bool { jobs.values.contains { !$0.state.isSettled } }

    func job(_ id: String) -> SetupJob? { jobs[id] }

    func view() -> JobsView {
        var view = JobsView()
        for job in jobs.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            if job.state.isSettled {
                view.open.removeValue(forKey: job.fix)
                if job.state == .failed { view.lastFailed[job.fix] = job } else { view.lastFailed.removeValue(forKey: job.fix) }
            } else {
                view.open[job.fix] = job
            }
        }
        return view
    }

    func start(fix: String) async throws -> SetupJob {
        guard let work = works[fix] else { throw SetupJobError.unknownFix }
        if let running = jobs.values.first(where: { $0.fix == fix && !$0.state.isSettled }) { throw SetupJobError.alreadyRunning(running) }
        guard await machineCanRunVoice() else { throw SetupJobError.unsupported }
        if let running = jobs.values.first(where: { $0.fix == fix && !$0.state.isSettled }) { throw SetupJobError.alreadyRunning(running) }
        let id = "job-" + UUID().uuidString.prefix(8).lowercased()
        let job = SetupJob(id: id, fix: fix, state: .running, step: "starting", startedAt: wall())
        jobs[id] = job
        store.save(job)
        let context = JobContext(id: id) { [weak self] progress in await self?.apply(progress, to: id) }
        contexts[id] = context
        tasks[id] = Task { [weak self] in
            let result = await work.run(context)
            await self?.finish(id, result: result)
        }
        logger.info("job started", metadata: ["job": "\(id)", "fix": "\(fix)"])
        return job
    }

    /// Cancels the job's processes (their whole group) and answers once it has settled. Files already
    /// on disk stay, so the same fix resumes from them.
    func cancel(_ id: String) async -> SetupJob? {
        guard let job = jobs[id] else { return nil }
        guard !job.state.isSettled, let context = contexts[id] else { return job }
        context.cancel()
        await tasks[id]?.value
        return jobs[id]
    }

    private func machineCanRunVoice() async -> Bool {
        guard let total = await probe.gpu()?.totalMB else { return false }
        return total >= VoiceRequirements.minimumCardMB
    }

    private func apply(_ progress: JobProgress, to id: String) {
        guard var job = jobs[id], !job.state.isSettled else { return }
        if let step = progress.step { job.step = step }
        if let fraction = progress.fraction { job.fraction = max(job.fraction ?? 0, fraction) }
        if let done = progress.bytesDone { job.bytesDone = done }
        if let total = progress.bytesTotal { job.bytesTotal = total }
        jobs[id] = job
        store.save(job)
    }

    private func finish(_ id: String, result: JobResult) {
        guard var job = jobs[id] else { return }
        let cancelled = contexts[id]?.isCancelled ?? false
        switch (cancelled, result) {
        case (true, _), (_, .cancelled):
            job.state = .cancelled
        case (_, .succeeded):
            job.state = .succeeded
            job.fraction = 1
            job.step = "done"
            job.failure = nil
        case (_, .failed(let failure)):
            job.state = .failed
            job.failure = failure.id
            job.facts = failure.facts
        }
        jobs[id] = job
        contexts.removeValue(forKey: id)
        tasks.removeValue(forKey: id)
        store.save(job)
        logger.info("job finished", metadata: ["job": "\(id)", "state": "\(job.state.rawValue)", "failure": "\(job.failure ?? "")"])
    }
}
