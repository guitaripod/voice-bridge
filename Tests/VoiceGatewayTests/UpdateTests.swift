import Foundation
import SetupKit
import Synchronization
import Testing
@testable import VoiceGatewayCore
import VoiceKit

final class ReleaseScript: Sendable {
    private let answers: Mutex<[String?]>
    private let asked = Mutex(0)

    init(_ answers: [String?]) { self.answers = Mutex(answers) }

    var count: Int { asked.withLock { $0 } }

    var fetch: ReleaseList.Fetch {
        { [self] in
            asked.withLock { $0 += 1 }
            return answers.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? nil }
        }
    }
}

struct ReleaseVersionTests {
    @Test(arguments: [("0.2.1", [0, 2, 1]), ("1", [1]), (" 10.0.3\n", [10, 0, 3])])
    func aNumberIsDigitsAndDots(text: String, parts: [Int]) {
        #expect(ReleaseVersion(text)?.parts == parts)
    }

    @Test(arguments: ["", "v1.2", "1..2", ".1", "1.", "1.2-beta", "<html>", "1.2.3 4", "٣.٢"])
    func anythingElseIsNotAVersion(text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func versionsCompareByNumberNotByText() throws {
        let low = try #require(ReleaseVersion("0.9.0"))
        let high = try #require(ReleaseVersion("0.10.0"))
        #expect(low < high)
        #expect(ReleaseVersion("1.0") == ReleaseVersion("1.0.0"))
        #expect(try #require(ReleaseVersion("1.0.1")) > #require(ReleaseVersion("1.0")))
    }

    @Test func theReleaseListUrlHangsOffTheBase() {
        #expect(ReleaseList.url(base: "https://x.test/releases/latest/download/")?.absoluteString == "https://x.test/releases/latest/download/latest.txt")
    }
}

struct UpdateCheckerTests {
    func checker(_ script: ReleaseScript, clock: ManualClock, current: String = "0.2.0") -> UpdateChecker {
        UpdateChecker(current: current, clock: clock, fetch: script.fetch)
    }

    @Test func behindWhenTheListNamesANewerRelease() async {
        let info = await checker(ReleaseScript(["0.3.0\n"]), clock: ManualClock()).info()
        #expect(info == UpdateInfo(current: "0.2.0", latest: "0.3.0", behind: true))
    }

    @Test func notBehindAtOrAheadOfTheList() async {
        #expect(await checker(ReleaseScript(["0.2.0"]), clock: ManualClock()).info().behind == false)
        #expect(await checker(ReleaseScript(["0.1.9"]), clock: ManualClock()).info().behind == false)
    }

    @Test func theAnswerIsCachedForHours() async {
        let script = ReleaseScript(["0.3.0"])
        let clock = ManualClock()
        let checker = checker(script, clock: clock)
        _ = await checker.info()
        clock.advance(by: UpdateChecker.freshSeconds - 1)
        _ = await checker.info()
        #expect(script.count == 1)
        clock.advance(by: 2)
        _ = await checker.info()
        #expect(script.count == 2)
    }

    @Test func aMachineThatIsOfflineSaysNothingIsKnownRatherThanBehind() async {
        let info = await checker(ReleaseScript([nil]), clock: ManualClock()).info()
        #expect(info == UpdateInfo(current: "0.2.0", latest: nil, behind: false))
    }

    @Test func goingOfflineKeepsTheLastVersionSeenAndRetriesSoon() async {
        let script = ReleaseScript(["0.3.0", nil, "0.4.0"])
        let clock = ManualClock()
        let checker = checker(script, clock: clock)
        #expect(await checker.info().latest == "0.3.0")
        clock.advance(by: UpdateChecker.freshSeconds + 1)
        let offline = await checker.info()
        #expect(offline.latest == "0.3.0" && offline.behind)
        clock.advance(by: UpdateChecker.retrySeconds - 1)
        _ = await checker.info()
        #expect(script.count == 2)
        clock.advance(by: 2)
        #expect(await checker.info().latest == "0.4.0")
    }

    @Test func aPageThatIsNotAVersionIsIgnored() async {
        #expect(await checker(ReleaseScript(["<html>Not Found</html>"]), clock: ManualClock()).info().latest == nil)
    }

    @Test func theRouteAnswersTheShapeTheAppsReadBehindTheSamePassword() async throws {
        let harness = await GatewayHarness.start(password: "s3cret", releases: ReleaseScript(["9.9.9"]).fetch)
        defer { Task { await harness.stop() } }
        #expect(try await harness.get("/update").0 == 401)
        let (status, body) = try await harness.get("/update", token: "s3cret")
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self) == #"{"behind":true,"current":"\#(GatewayInfo.version)","latest":"9.9.9"}"#)
    }

    @Test func theConfigTakesTheReleaseBaseFromTheEnvironment() {
        #expect(GatewayConfig(environment: [:]).releaseBase == UpdateWire.defaultReleaseBase)
        #expect(GatewayConfig(environment: ["VOICE_RELEASE_BASE": "http://127.0.0.1:1/x"]).releaseBase == "http://127.0.0.1:1/x")
    }
}

struct UpdateGuardTests {
    func health(calls: Int = 0, engine: VoiceEngineState = .ready) -> GatewayAnswer<VoiceHealth> {
        .answered(VoiceHealth(gateway: "0.2.0", engine: engine, calls: calls))
    }

    func idle() -> GatewayAnswer<[SetupReport]> {
        .answered([SetupReport(capability: "voice", ready: true, checks: [SetupCheck(id: "voice.gpu", state: .ok)])])
    }

    @Test func anIdleGatewayMayBeRestarted() async {
        #expect(await UpdateGuard.verdict(health: health(), setup: idle) == .safe)
        #expect(await UpdateGuard.verdict(health: health(engine: .stopped), setup: idle) == .safe)
    }

    @Test func aCallInProgressMustNotBeCut() async {
        #expect(await UpdateGuard.verdict(health: health(calls: 1, engine: .busy), setup: idle) == .wait("a call is in progress"))
    }

    @Test func anEngineLoadMustNotBeDropped() async {
        #expect(await UpdateGuard.verdict(health: health(engine: .loading), setup: idle) == .wait("the voice engine is loading"))
    }

    @Test func aDownloadMustNotBeKilled() async {
        let job = SetupJob(id: "job-1", fix: "voice.downloadModel", state: .running, startedAt: 1)
        let working = SetupCheck(id: "voice.model", state: .working)
        let report = SetupReport(capability: "voice", ready: false, checks: [working], job: job)
        #expect(await UpdateGuard.verdict(health: health(), setup: { .answered([report]) }) == .wait("the voice model is downloading"))
        let pull = SetupReport(
            capability: "voice", ready: false, checks: [SetupCheck(id: "voice.image", state: .working)])
        #expect(await UpdateGuard.verdict(health: health(), setup: { .answered([pull]) }) == .wait("the voice engine image is downloading"))
        let jobOnly = SetupReport(capability: "voice", ready: false, checks: [], job: SetupJob(id: "j", fix: "voice.pullImage", state: .running))
        #expect(await UpdateGuard.verdict(health: health(), setup: { .answered([jobOnly]) }) == .wait("the voice engine image is downloading"))
    }

    @Test func aGatewayThatCannotBeAskedIsNotAssumedIdle() async {
        #expect(await UpdateGuard.verdict(health: .unreadable("the password was refused"), setup: idle) == .unknown("the password was refused"))
        #expect(await UpdateGuard.verdict(health: health(), setup: { .unreadable("HTTP 500") }) == .unknown("HTTP 500"))
    }

    @Test func aGatewayThatIsNotRunningHasNothingToLose() async {
        #expect(await UpdateGuard.verdict(health: .notRunning, setup: idle) == .notRunning)
    }
}

final class StubGateway: RunningGateway {
    private let healthAnswer = Mutex<GatewayAnswer<VoiceHealth>>(.notRunning)
    private let setupAnswer = Mutex<GatewayAnswer<[SetupReport]>>(.answered([]))
    private let asked = Mutex(0)

    init(running version: String?, calls: Int = 0, engine: VoiceEngineState = .ready) {
        if let version { healthAnswer.withLock { $0 = .answered(VoiceHealth(gateway: version, engine: engine, calls: calls)) } }
    }

    func comesUp(as version: String) { healthAnswer.withLock { $0 = .answered(VoiceHealth(gateway: version, engine: .ready)) } }
    func setHealth(_ answer: GatewayAnswer<VoiceHealth>) { healthAnswer.withLock { $0 = answer } }
    func setSetup(_ answer: GatewayAnswer<[SetupReport]>) { setupAnswer.withLock { $0 = answer } }
    var healthChecks: Int { asked.withLock { $0 } }

    func health() async -> GatewayAnswer<VoiceHealth> {
        asked.withLock { $0 += 1 }
        return healthAnswer.withLock { $0 }
    }

    func setup() async -> GatewayAnswer<[SetupReport]> { setupAnswer.withLock { $0 } }
}

struct UpdateCommandTests {
    struct Rig {
        let share: URL
        let output = Collected()
        let gateway: StubGateway
        let runner: ScriptedRunner

        func command(current: String = "0.2.0", latest: String? = "0.3.0") -> UpdateCommand {
            let out = output
            return UpdateCommand(
                environment: ["VOICE_SHARE_DIR": share.path, "VOICE_UNIT": "test.service"], runner: runner, gateway: gateway,
                releases: ReleaseScript([latest]).fetch, current: current, healthAttempts: 3, pollSeconds: 0.01, emit: { out.add($0 + "\n") })
        }
    }

    func rig(
        installer: Bool = true, running: String? = "0.2.0", calls: Int = 0, installStatus: Int32 = 0, enabled: Bool = true,
        restartStatus: Int32 = 0, engine: VoiceEngineState = .ready, after: String? = "0.3.0"
    ) -> Rig {
        let share = FileManager.default.temporaryDirectory.appendingPathComponent("voice-share-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        if installer { try? "#!/bin/sh\n".write(to: share.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8) }
        let gateway = StubGateway(running: running, calls: calls, engine: engine)
        let runner = ScriptedRunner { spec in
            switch spec.executable {
            case "bash": return CommandResult(status: installStatus, output: "downloading the latest voice-bridge\ninstalled voice-bridge 0.3.0\n")
            case "systemctl":
                switch spec.arguments[1] {
                case "is-enabled": return CommandResult(status: enabled ? 0 : 1)
                default:
                    if restartStatus == 0, let after { gateway.comesUp(as: after) }
                    return CommandResult(status: restartStatus, error: restartStatus == 0 ? "" : "Failed to restart")
                }
            default: return nil
            }
        }
        return Rig(share: share, gateway: gateway, runner: runner)
    }

    @Test func behindAndIdleInstallsThenRestartsAndConfirmsTheNewVersion() async {
        let rig = rig()
        defer { try? FileManager.default.removeItem(at: rig.share) }
        let status = await rig.command().run()
        #expect(status == 0)
        let install = rig.runner.called("bash")
        #expect(install.count == 1)
        #expect(install[0].arguments == [rig.share.appendingPathComponent("install.sh").path, "--update"])
        #expect(rig.runner.called("systemctl", "--user").map(\.arguments) == [["--user", "is-enabled", "test.service"], ["--user", "restart", "test.service"]])
        #expect(rig.output.text.contains("Updating voice-bridge 0.2.0 to 0.3.0."))
        #expect(rig.output.text.contains("installed voice-bridge 0.3.0"))
        #expect(rig.output.text.hasSuffix("voice-bridge 0.3.0 is running.\n"))
    }

    @Test func aCallInProgressGetsTheInstallButNoRestart() async {
        let rig = rig(calls: 1, engine: .busy)
        defer { try? FileManager.default.removeItem(at: rig.share) }
        let status = await rig.command().run()
        #expect(status == UpdateCommand.deferred)
        #expect(rig.runner.called("bash").count == 1)
        #expect(rig.runner.called("systemctl").isEmpty)
        #expect(rig.output.text.contains("voice-bridge 0.3.0 is installed but not running yet. A call is in progress, and a restart would cut it off."))
        #expect(rig.output.text.contains("Run `voice-bridge update` again when that is over."))
    }

    @Test func aDownloadOrAnEngineLoadHoldsTheRestartToo() async {
        let loading = rig(engine: .loading)
        defer { try? FileManager.default.removeItem(at: loading.share) }
        #expect(await loading.command().run() == UpdateCommand.deferred)
        #expect(loading.runner.called("systemctl").isEmpty)

        let download = rig()
        defer { try? FileManager.default.removeItem(at: download.share) }
        download.gateway.setSetup(.answered([SetupReport(capability: "voice", ready: false, checks: [SetupCheck(id: "voice.model", state: .working)])]))
        #expect(await download.command().run() == UpdateCommand.deferred)
        #expect(download.runner.called("systemctl").isEmpty)
        #expect(download.output.text.contains("The voice model is downloading"))
    }

    @Test func aGatewayThatCannotBeAskedIsNotRestartedEither() async {
        let rig = rig()
        defer { try? FileManager.default.removeItem(at: rig.share) }
        rig.gateway.setHealth(.unreadable("the password was refused"))
        #expect(await rig.command().run() == UpdateCommand.deferred)
        #expect(rig.runner.called("systemctl").isEmpty)
        #expect(rig.output.text.contains("could not be asked whether it is busy (the password was refused)"))
    }

    @Test func runningItAgainOnceIdleOnlyRestarts() async {
        let rig = rig(running: "0.2.0")
        defer { try? FileManager.default.removeItem(at: rig.share) }
        let status = await rig.command(current: "0.3.0", latest: "0.3.0").run()
        #expect(status == 0)
        #expect(rig.runner.called("bash").isEmpty)
        #expect(rig.runner.called("systemctl", "--user").count == 2)
        #expect(rig.output.text.contains("voice-bridge 0.3.0 is the newest release."))
        #expect(rig.output.text.hasSuffix("voice-bridge 0.3.0 is running.\n"))
    }

    @Test func nothingToDoWhenTheRunningGatewayIsTheNewestRelease() async {
        let rig = rig(running: "0.3.0")
        defer { try? FileManager.default.removeItem(at: rig.share) }
        #expect(await rig.command(current: "0.3.0", latest: "0.3.0").run() == 0)
        #expect(rig.runner.calls.isEmpty)
        #expect(rig.output.text.contains("The running gateway is already 0.3.0."))
    }

    @Test func aGatewayThatIsNotRunningIsStartedByTheRestart() async {
        let rig = rig(running: nil)
        defer { try? FileManager.default.removeItem(at: rig.share) }
        #expect(await rig.command().run() == 0)
        #expect(rig.runner.called("systemctl", "--user").count == 2)
    }

    @Test func aFailedInstallLeavesTheRunningGatewayAlone() async {
        let rig = rig(installStatus: 1)
        defer { try? FileManager.default.removeItem(at: rig.share) }
        #expect(await rig.command().run() == 1)
        #expect(rig.runner.called("systemctl").isEmpty)
        #expect(rig.output.text.contains("The update did not install, and the running gateway was not touched."))
    }

    @Test func withoutAStagedInstallerItSaysSoAndChangesNothing() async {
        let rig = rig(installer: false)
        defer { try? FileManager.default.removeItem(at: rig.share) }
        #expect(await rig.command().run() == 1)
        #expect(rig.runner.calls.isEmpty)
        #expect(rig.output.text.contains("There is no installer at \(rig.share.path)/install.sh"))
    }

    @Test func anUnreadableReleaseListChangesNothing() async {
        let rig = rig()
        defer { try? FileManager.default.removeItem(at: rig.share) }
        #expect(await rig.command(latest: nil).run() == 1)
        #expect(rig.runner.calls.isEmpty)
        #expect(rig.output.text.contains("Could not read the list of releases, so nothing was changed."))
    }

    @Test func noServiceMeansTheGatewayIsStartedByHand() async {
        let rig = rig(enabled: false)
        defer { try? FileManager.default.removeItem(at: rig.share) }
        #expect(await rig.command().run() == 0)
        #expect(rig.runner.called("systemctl", "--user").count == 1)
        #expect(rig.output.text.contains("No service named test.service manages the gateway"))
    }

    @Test func aRestartThatFailsOrNeverAnswersIsReportedHonestly() async {
        let failed = rig(restartStatus: 1)
        defer { try? FileManager.default.removeItem(at: failed.share) }
        #expect(await failed.command().run() == 1)
        #expect(failed.output.text.contains("The service did not restart: Failed to restart."))

        let silent = rig(after: nil)
        defer { try? FileManager.default.removeItem(at: silent.share) }
        #expect(await silent.command().run() == 1)
        #expect(silent.output.text.contains("is not answering as 0.3.0 yet"))
        #expect(silent.gateway.healthChecks >= 3)
    }
}

@Suite(.serialized)
struct HTTPRunningGatewayTests {
    @Test func readsHealthAndSetupFromARealGatewayWithItsPassword() async throws {
        let harness = await MachineGatewayHarness.start(password: "s3cret")
        defer { Task { await harness.stop() } }
        let gateway = HTTPRunningGateway(port: harness.port, password: "s3cret")
        guard case .answered(let health) = await gateway.health() else {
            Issue.record("health was not answered")
            return
        }
        #expect(health.gateway == GatewayInfo.version)
        guard case .answered(let reports) = await gateway.setup() else {
            Issue.record("setup was not answered")
            return
        }
        #expect(reports.first?.capability == "voice")
    }

    @Test func aRefusedPasswordIsUnreadableNotIdle() async {
        let harness = await MachineGatewayHarness.start(password: "s3cret")
        defer { Task { await harness.stop() } }
        let answer = await HTTPRunningGateway(port: harness.port, password: "wrong").health()
        #expect(answer == .unreadable("the password was refused"))
    }

    @Test func aGatewayWithoutSetupRoutesHasNoSetupToWaitFor() async {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        #expect(await HTTPRunningGateway(port: harness.port, password: nil).setup() == .answered([]))
    }

    @Test func nothingListeningIsNotRunning() async throws {
        let harness = await GatewayHarness.start()
        let port = harness.port
        await harness.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await HTTPRunningGateway(port: port, password: nil, timeout: 2).health() == .notRunning)
    }
}
