import Foundation

/// Everything `voice-bridge` does besides serving. `serve` is not here: the executable runs the
/// gateway itself when no command was given.
public enum GatewayCLI {
    public static let refusedStatus: Int32 = 2

    public static func versionLine() -> String { "voice-bridge \(GatewayInfo.version)" }

    public static func run(
        _ command: GatewayCommand, environment: [String: String], out: @escaping @Sendable (String) -> Void,
        err: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        switch command {
        case .serve:
            return 0
        case .version:
            out(versionLine() + "\n")
            return 0
        case .help:
            out(GatewayCommand.usage + "\n")
            return 0
        case .refused(let reason):
            err("voice-bridge: \(reason)\n\n\(GatewayCommand.usage)\n")
            return refusedStatus
        case .doctor(let options):
            let layered = EnvFile.layered(over: environment)
            let outcome = await DoctorCommand.run(
                options: options, environment: layered, unicode: DoctorCommand.terminalUnicode(environment: environment))
            out(outcome.text)
            return outcome.status
        case .update:
            let layered = EnvFile.layered(over: environment)
            return await UpdateCommand(environment: layered, emit: { out($0 + "\n") }).run()
        }
    }
}
