import Foundation

/// `voice-bridge update`: fetches the newest release through the installer that was left on this
/// machine, and restarts the service only when the running gateway has nothing to lose. The program on
/// disk is replaced either way; a gateway that could not be restarted keeps serving until the command
/// is run again, which then only restarts.
public struct UpdateCommand: Sendable {
    public static let deferred: Int32 = 4

    let environment: [String: String]
    let runner: any CommandRunner
    let gateway: any RunningGateway
    let releases: ReleaseList.Fetch
    let clock: any VoiceClock
    let emit: @Sendable (String) -> Void
    let current: String
    let healthAttempts: Int
    let pollSeconds: Double

    public init(
        environment: [String: String], runner: (any CommandRunner)? = nil, gateway: (any RunningGateway)? = nil,
        releases: ReleaseList.Fetch? = nil, clock: any VoiceClock = SystemVoiceClock(), current: String = GatewayInfo.version,
        healthAttempts: Int = 30, pollSeconds: Double = 1, emit: @escaping @Sendable (String) -> Void
    ) {
        self.environment = environment
        self.runner = runner ?? ProcessRunner(environment: environment)
        self.gateway = gateway ?? HTTPRunningGateway(environment: environment)
        self.releases = releases ?? ReleaseList.fetcher(base: GatewayConfig(environment: environment).releaseBase)
        self.clock = clock
        self.current = current
        self.healthAttempts = healthAttempts
        self.pollSeconds = pollSeconds
        self.emit = emit
    }

    var shareDirectory: String {
        if let explicit = environment["VOICE_SHARE_DIR"], !explicit.isEmpty { return explicit }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return "\(home)/.local/share/voice-bridge"
    }

    var installer: String { "\(shareDirectory)/install.sh" }

    var unit: String { environment["VOICE_UNIT"].flatMap { $0.isEmpty ? nil : $0 } ?? "voice-bridge.service" }

    public func run() async -> Int32 {
        guard let latest = await ReleaseList.latest(releases), let running = ReleaseVersion(current) else {
            emit("Could not read the list of releases, so nothing was changed.")
            return 1
        }
        var installed = running
        if running < latest {
            guard await install(latest) else { return 1 }
            installed = latest
        } else {
            emit("voice-bridge \(running) is the newest release.")
        }
        return await restartIfIdle(installed: installed)
    }

    private func install(_ latest: ReleaseVersion) async -> Bool {
        guard FileManager.default.isReadableFile(atPath: installer) else {
            emit("There is no installer at \(installer), so this copy was not put here by the installer. Run the install command again instead.")
            return false
        }
        emit("Updating voice-bridge \(current) to \(latest).")
        let process = runner.stream(CommandSpec("bash", [installer, "--update"]))
        for await line in process.lines { emit(line) }
        let result = await process.wait()
        guard result.succeeded else {
            emit("The update did not install, and the running gateway was not touched.")
            return false
        }
        return true
    }

    private func restartIfIdle(installed: ReleaseVersion) async -> Int32 {
        let health = await gateway.health()
        if case .answered(let answer) = health, let running = ReleaseVersion(answer.gateway), running >= installed {
            emit("The running gateway is already \(running).")
            return 0
        }
        let verdict = await UpdateGuard.verdict(health: health, setup: { await gateway.setup() })
        switch verdict {
        case .wait(let why):
            return deferRestart(installed, "\(why.prefix(1).uppercased())\(why.dropFirst()), and a restart would cut it off")
        case .unknown(let why):
            return deferRestart(installed, "the running gateway could not be asked whether it is busy (\(why))")
        case .safe, .notRunning:
            return await restart(installed)
        }
    }

    private func deferRestart(_ installed: ReleaseVersion, _ why: String) -> Int32 {
        emit("voice-bridge \(installed) is installed but not running yet. \(why). Run `voice-bridge update` again when that is over.")
        return Self.deferred
    }

    private func restart(_ installed: ReleaseVersion) async -> Int32 {
        let enabled = await runner.run(CommandSpec("systemctl", ["--user", "is-enabled", unit], timeout: 15))
        guard enabled.succeeded else {
            emit("voice-bridge \(installed) is installed. No service named \(unit) manages the gateway, so start it again yourself.")
            return 0
        }
        emit("Restarting \(unit).")
        let result = await runner.run(CommandSpec("systemctl", ["--user", "restart", unit], timeout: 60))
        guard result.succeeded else {
            emit("The service did not restart: \(result.tail(2).joined(separator: " ")). Look with `journalctl --user -u \(unit)`.")
            return 1
        }
        guard await answersAs(installed) else {
            emit("The service restarted but is not answering as \(installed) yet. Look with `journalctl --user -u \(unit)`.")
            return 1
        }
        emit("voice-bridge \(installed) is running.")
        return 0
    }

    private func answersAs(_ installed: ReleaseVersion) async -> Bool {
        for attempt in 0..<healthAttempts {
            if attempt > 0 { try? await clock.sleep(until: clock.now() + pollSeconds) }
            if case .answered(let answer) = await gateway.health(), ReleaseVersion(answer.gateway) == installed { return true }
        }
        return false
    }
}
