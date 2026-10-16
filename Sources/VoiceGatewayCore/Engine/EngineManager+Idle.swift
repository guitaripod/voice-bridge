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

    /// `docker stop` on the one container this gateway owns, by its exact name and nothing else.
    func stopOurContainer() async {
        _ = await runner.run(CommandSpec("docker", ["stop", VoiceRequirements.containerName], timeout: settings.stopTimeoutSeconds))
        await facts.forget()
    }
}
