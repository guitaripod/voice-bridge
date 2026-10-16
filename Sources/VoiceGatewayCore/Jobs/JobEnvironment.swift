import Foundation

/// What every job needs from the machine it runs on.
struct JobEnvironment: Sendable {
    let runner: any CommandRunner
    let probe: MachineProbe
    let paths: MachinePaths
    let clock: any VoiceClock
    let gatewayEnvironment: [String: String]
    let pollSeconds: Double
    let ngcPackage: @Sendable (String) -> NGCRelease.Package?

    init(
        runner: any CommandRunner, probe: MachineProbe, paths: MachinePaths, clock: any VoiceClock,
        gatewayEnvironment: [String: String] = [:], pollSeconds: Double = 1,
        ngcPackage: @escaping @Sendable (String) -> NGCRelease.Package? = NGCRelease.package(machine:)
    ) {
        self.runner = runner
        self.probe = probe
        self.paths = paths
        self.clock = clock
        self.gatewayEnvironment = gatewayEnvironment
        self.pollSeconds = pollSeconds
        self.ngcPackage = ngcPackage
    }

    /// The NGC CLI reads `NGC_CLI_API_KEY`; the NIM documentation calls the same key `NGC_API_KEY`.
    var ngcEnvironment: [String: String] {
        guard gatewayEnvironment["NGC_CLI_API_KEY"] == nil, let key = gatewayEnvironment["NGC_API_KEY"], !key.isEmpty else { return [:] }
        return ["NGC_CLI_API_KEY": key]
    }
}
