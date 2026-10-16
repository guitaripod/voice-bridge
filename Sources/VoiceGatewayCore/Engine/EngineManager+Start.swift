import Foundation

enum StartOutcome: Sendable, Equatable {
    case external
    case status(EngineStatus)
}

extension EngineManager {
    /// Without `--rm`, so the log survives an engine that dies while loading; the gateway removes the
    /// container itself. The two shares are the memory each of the NIM's two vLLM engines reserves.
    static func runArguments(modelRoot: String, llmMemUtil: Double, ttsMemUtil: Double) -> [String] {
        [
            "run", "-d", "--name", VoiceRequirements.containerName, "--device", "nvidia.com/gpu=0", "--shm-size=8GB",
            "-e", "NIM_HTTP_API_PORT=\(VoiceRequirements.nimPort)",
            "-e", "LLM_GPU_MEM_UTIL=\(share(llmMemUtil))", "-e", "TTS_GPU_MEM_UTIL=\(share(ttsMemUtil))",
            "-p", "127.0.0.1:\(VoiceRequirements.nimPort):\(VoiceRequirements.nimPort)",
            "-v", "\(modelRoot):/data/models", "--entrypoint", "/s2s/run_s2s_server.sh", VoiceRequirements.imageName,
        ]
    }

    static func share(_ value: Double) -> String { String(format: "%.2f", value) }

    /// A call wants the engine. When it is stopped and the GPU has the memory, the container starts and
    /// the answer is `loading`; anything else is reported as it is and nothing is started.
    func requestStart() async -> StartOutcome {
        let reading = await facts.fresh()
        guard await isManaged(reading) else { return .external }
        let current = derive(reading, managed: true)
        switch current {
        case .ready, .needsSetup, .busy:
            return .status(current)
        case .loading:
            if loadTask == nil { beginLoad() }
            return .status(derive(reading, managed: true))
        case .stopped, .down:
            return .status(await start(reading))
        }
    }

    private func start(_ reading: MachineFacts) async -> EngineStatus {
        let gpu = await probe.gpu()
        let free = gpu?.freeMB ?? 0
        guard free >= VoiceRequirements.freeVRAMMB else {
            logger.info("engine start refused, gpu not free", metadata: ["freeMB": "\(free)"])
            return .busy(freeMB: free, needMB: VoiceRequirements.freeVRAMMB, holders: gpu?.holderNames ?? [])
        }
        if case .other = reading.container {
            _ = await runner.run(CommandSpec("docker", ["rm", "-f", VoiceRequirements.containerName], timeout: 60))
        }
        activity.touch(at: clock.now())
        let arguments = Self.runArguments(modelRoot: reading.model.root.path, llmMemUtil: settings.llmMemUtil, ttsMemUtil: settings.ttsMemUtil)
        let result = await runner.run(CommandSpec("docker", arguments, timeout: 120))
        await facts.forget()
        guard result.succeeded else {
            let reason = result.tail(2).joined(separator: " ")
            let said = reason.isEmpty ? "the container did not start" : reason
            fail(.startFailed(said, tail: result.tail(EngineFailure.tailLines)))
            logger.warning("engine start failed", metadata: ["reason": "\(reason)"])
            return .down(reason: said)
        }
        logger.info("engine container started")
        beginLoad()
        return .loading(progress: 0)
    }

    func beginLoad() {
        load = .loading(0)
        let started = clock.now()
        loadTask = Task { [weak self] in await self?.pollLoad(from: started) }
    }

    private func fail(_ detail: EngineFailure) {
        load = .failed(detail.reason)
        failure = detail
        failedAt = clock.now()
    }

    /// Watches the NIM until it reports ready. Progress is the time spent against a typical load, which
    /// is a picture and not a measurement: the NIM reports no percentage.
    private func pollLoad(from started: Double) async {
        defer { loadTask = nil }
        var lastContainerCheck = started
        while !Task.isCancelled {
            let elapsed = clock.now() - started
            load = .loading(min(0.99, elapsed / settings.typicalLoadSeconds))
            if await nim.check() == .ready {
                load = .ready
                activity.touch(at: clock.now())
                await facts.forget()
                logger.info("engine ready", metadata: ["seconds": "\(Int(elapsed))"])
                return
            }
            if elapsed >= settings.loadTimeoutSeconds {
                let log = await containerLog()
                fail(.notReady(minutes: Int(settings.loadTimeoutSeconds / 60), log: log))
                logFailure(log)
                await stopOurContainer()
                return
            }
            if clock.now() - lastContainerCheck >= 10 {
                lastContainerCheck = clock.now()
                if await loadAborted() { return }
            }
            do { try await clock.sleep(until: clock.now() + settings.pollSeconds) } catch { return }
        }
    }

    /// The container is gone or has exited while it was loading. Its log is read first, because removing
    /// the container removes the log, and goes into the failure and the gateway's own log.
    private func loadAborted() async -> Bool {
        let state = await probe.containerState()
        switch state {
        case .running, .other("created"), .other("restarting"), .other("paused"):
            return false
        case .absent, .other:
            let log = state == .absent ? [] : await containerLog()
            let free = await probe.gpu()?.freeMB ?? 0
            let detail = EngineFailure.exited(log: log, freeMB: free)
            fail(detail)
            logFailure(log, detail: detail)
            if state != .absent { await removeOurContainer() }
            return true
        }
    }

    private func logFailure(_ log: [String], detail: EngineFailure? = nil) {
        logger.warning(
            "voice engine did not come up",
            metadata: ["failure": "\(detail?.id ?? failure?.id ?? "-")", "reason": "\(detail?.reason ?? failure?.reason ?? "-")", "log": "\(log.joined(separator: "\n"))"])
    }
}
