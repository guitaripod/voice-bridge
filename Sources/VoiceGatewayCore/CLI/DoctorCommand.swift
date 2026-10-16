import Foundation
import Logging
import SetupKit

/// `voice-bridge doctor`: the same checklist the gateway serves on `/setup`, read from this machine
/// without a running gateway. It starts no job and touches no file, so it is safe next to a live one.
public enum DoctorCommand {
    public static let cannotRunVoice: Int32 = 3

    public struct Outcome: Sendable, Equatable {
        public var text: String
        public var status: Int32
    }

    public static func run(
        options: GatewayCommand.DoctorOptions, environment: [String: String], unicode: Bool,
        runner: (any CommandRunner)? = nil, nim: (any NIMHealthProbe)? = nil, clock: any VoiceClock = SystemVoiceClock()
    ) async -> Outcome {
        let config = GatewayConfig(environment: environment)
        let probe = MachineProbe(
            runner: runner ?? ProcessRunner(environment: environment), paths: MachinePaths(environment: environment),
            nim: nim ?? HTTPNIMHealthProbe(nimURL: config.nimURL))
        let settings = EngineSettings(
            mode: EngineMode.effective(config.engine, nimURL: config.nimURL), idleStopSeconds: config.idleStopMinutes * 60)
        let report = await diagnose(probe: probe, settings: settings, clock: clock)
        return outcome(report, options: options, unicode: unicode)
    }

    static func diagnose(probe: MachineProbe, settings: EngineSettings, clock: any VoiceClock) async -> SetupReport {
        let facts = FactsCache(probe: probe, clock: clock)
        let engine = EngineManager(
            settings: settings, probe: probe, facts: facts, runner: probe.runner, nim: probe.nim, clock: clock,
            activity: EngineActivity(now: clock.now()), logger: Logger(label: "voice.doctor") { _ in SwiftLogNoOpLogHandler() })
        let reading = await facts.fresh()
        let managed = await engine.isManaged(reading)
        let status = await engine.derive(reading, managed: managed)
        return Doctor(facts: reading, engine: status, managed: managed, jobs: JobsView(), version: GatewayInfo.version).report()
    }

    static func outcome(_ report: SetupReport, options: GatewayCommand.DoctorOptions, unicode: Bool) -> Outcome {
        let status = report.available ? 0 : cannotRunVoice
        let text = DoctorText(unicode: unicode)
        if options.json {
            let data = (try? SetupCodec.encode(report)) ?? Data()
            return Outcome(text: String(decoding: data, as: UTF8.self) + "\n", status: status)
        }
        if options.commands {
            return Outcome(text: text.commands(report).map { $0 + "\n" }.joined(), status: status)
        }
        return Outcome(text: text.render(report), status: status)
    }

    public static func terminalUnicode(environment: [String: String]) -> Bool {
        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
        let lowered = locale.lowercased()
        return lowered.contains("utf-8") || lowered.contains("utf8")
    }
}
