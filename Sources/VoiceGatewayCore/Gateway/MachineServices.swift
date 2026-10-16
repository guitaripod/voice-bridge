import Foundation
import Logging
import SetupKit

/// Everything the gateway does about its own machine: the doctor's facts, the setup jobs and the
/// engine manager. A gateway without it behaves as before, talking to a NIM somebody else runs.
public struct MachineServices: Sendable {
    let probe: MachineProbe
    let facts: FactsCache
    let jobs: SetupJobs
    let engine: EngineManager
    let activity: EngineActivity

    init(
        runner: any CommandRunner, paths: MachinePaths, nim: any NIMHealthProbe, settings: EngineSettings,
        clock: any VoiceClock, environment: [String: String] = [:], pollSeconds: Double = 1,
        ngcPackage: @escaping @Sendable (String) -> NGCRelease.Package? = NGCRelease.package(machine:),
        logger: Logger = Logger(label: "voice.machine")
    ) {
        probe = MachineProbe(runner: runner, paths: paths, nim: nim)
        facts = FactsCache(probe: probe, clock: clock)
        let jobEnvironment = JobEnvironment(
            runner: runner, probe: probe, paths: paths, clock: clock, gatewayEnvironment: environment, pollSeconds: pollSeconds,
            ngcPackage: ngcPackage)
        jobs = SetupJobs(
            store: JobStore(directory: paths.jobsDir),
            works: [
                VoiceRequirements.downloadModelFix: ModelDownloadJob(environment: jobEnvironment),
                VoiceRequirements.pullImageFix: ImagePullJob(environment: jobEnvironment),
            ],
            probe: probe, logger: logger)
        activity = EngineActivity(now: clock.now())
        let jobs = self.jobs
        engine = EngineManager(
            settings: settings, probe: probe, facts: facts, runner: runner, nim: nim, clock: clock, activity: activity,
            jobsActive: { await jobs.hasOpenJob }, logger: logger)
    }

    public static func live(config: GatewayConfig, environment: [String: String], clock: any VoiceClock, logger: Logger) -> MachineServices {
        let settings = EngineSettings(
            mode: EngineMode.effective(config.engine, nimURL: config.nimURL), idleStopSeconds: config.idleStopMinutes * 60)
        return MachineServices(
            runner: ProcessRunner(environment: environment), paths: MachinePaths(environment: environment),
            nim: HTTPNIMHealthProbe(nimURL: config.nimURL), settings: settings, clock: clock, environment: environment, logger: logger)
    }

    func reports() async -> [SetupReport] {
        let reading = await facts.fresh()
        let managed = await engine.isManaged(reading)
        let status = await engine.derive(reading, managed: managed)
        let view = await jobs.view()
        return [Doctor(facts: reading, engine: status, managed: managed, jobs: view, version: GatewayInfo.version).report()]
    }

    /// Runs until cancelled: the idle stop of the engine.
    public func run() async {
        await engine.monitor()
    }
}
