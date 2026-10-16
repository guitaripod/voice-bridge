import Foundation

enum StartOutcome: Sendable, Equatable {
    case external
    case status(EngineStatus)
}

extension EngineManager {
    static func runArguments(modelRoot: String) -> [String] {
        [
            "run", "-d", "--rm", "--name", VoiceRequirements.containerName, "--device", "nvidia.com/gpu=0", "--shm-size=8GB",
            "-e", "NIM_HTTP_API_PORT=\(VoiceRequirements.nimPort)", "-p", "127.0.0.1:\(VoiceRequirements.nimPort):\(VoiceRequirements.nimPort)",
            "-v", "\(modelRoot):/data/models", "--entrypoint", "/s2s/run_s2s_server.sh", VoiceRequirements.imageName,
        ]
    }

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
        let result = await runner.run(CommandSpec("docker", Self.runArguments(modelRoot: reading.model.root.path), timeout: 120))
        await facts.forget()
        guard result.succeeded else {
            let reason = result.tail(2).joined(separator: " ")
            fail(reason.isEmpty ? "the container did not start" : reason)
            logger.warning("engine start failed", metadata: ["reason": "\(reason)"])
            return .down(reason: reason.isEmpty ? "the container did not start" : reason)
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

    private func fail(_ reason: String) {
        load = .failed(reason)
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
                fail("the voice engine was not ready after \(Int(settings.loadTimeoutSeconds / 60)) minutes")
                await stopOurContainer()
                return
            }
            if clock.now() - lastContainerCheck >= 10 {
                lastContainerCheck = clock.now()
                if await probe.containerState() == .absent {
                    fail("the voice engine container stopped while loading")
                    return
                }
            }
            do { try await clock.sleep(until: clock.now() + settings.pollSeconds) } catch { return }
        }
    }
}
