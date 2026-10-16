import Foundation

extension EngineManager {
    /// Looks at the engine every so often and stops it once nobody has wanted it for the idle time.
    func monitor() async {
        while !Task.isCancelled {
            do { try await clock.sleep(until: clock.now() + settings.monitorSeconds) } catch { return }
            await stopIfIdle()
        }
    }

    func stopIfIdle() async {
        guard settings.idleStopSeconds > 0, loadTask == nil, activity.calls == 0 else { return }
        guard clock.now() - activity.last >= settings.idleStopSeconds else { return }
        guard await !jobsActive() else {
            activity.touch(at: clock.now())
            return
        }
        let reading = await facts.fresh()
        guard await isManaged(reading), reading.container == .running, activity.calls == 0 else { return }
        logger.info("stopping the idle voice engine")
        await stopOurContainer()
        load = .idle
    }

    /// `docker stop` and then `docker rm -f` on the one container this gateway owns, by its exact name and
    /// nothing else. The container has no `--rm`, so its log outlives a crash until it is removed here.
    func stopOurContainer() async {
        _ = await runner.run(CommandSpec("docker", ["stop", VoiceRequirements.containerName], timeout: settings.stopTimeoutSeconds))
        await removeOurContainer()
    }

    func removeOurContainer() async {
        _ = await runner.run(CommandSpec("docker", ["rm", "-f", VoiceRequirements.containerName], timeout: 60))
        await facts.forget()
    }

    /// The last lines the container printed, read before it is removed.
    func containerLog() async -> [String] {
        let result = await runner.run(
            CommandSpec("docker", ["logs", "--tail", "\(EngineFailure.logLines)", VoiceRequirements.containerName], timeout: 30))
        let text = [result.output, result.error].filter { !$0.isEmpty }.joined(separator: "\n")
        return text.split(whereSeparator: \.isNewline).map(String.init).suffix(EngineFailure.logLines).map { $0 }
    }
}
