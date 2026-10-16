import Foundation
import Testing
@testable import VoiceGatewayCore

struct VersionTests {
    static func changelogVersions() throws -> [String] {
        let changelog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("## ") else { return nil }
            let word = line.dropFirst(3).split(separator: " ").first.map(String.init)
            return word.flatMap { $0.first?.isNumber == true ? $0 : nil }
        }
    }

    @Test func theCompiledVersionIsTheChangelogHead() throws {
        #expect(try Self.changelogVersions().first == GatewayInfo.version)
    }

    @Test func everyChangelogHeadingIsAVersionTheInstallerWouldAccept() throws {
        let versions = try Self.changelogVersions()
        #expect(!versions.isEmpty)
        for version in versions { #expect(ReleaseVersion(version) != nil, "\(version)") }
    }

    @Test func theVersionLineNamesTheProgramAndItsVersion() {
        #expect(GatewayCLI.versionLine() == "voice-bridge \(GatewayInfo.version)")
    }

    @Test(arguments: [
        ([], GatewayCommand.serve),
        (["--version"], .version),
        (["version"], .version),
        (["help"], .help),
        (["--help"], .help),
        (["doctor"], .doctor(.init())),
        (["doctor", "--json"], .doctor(.init(json: true))),
        (["doctor", "--commands"], .doctor(.init(commands: true))),
        (["update"], .update),
    ])
    func knownWordsAreCommands(arguments: [String], expected: GatewayCommand) {
        #expect(GatewayCommand.parse(arguments) == expected)
    }

    @Test(arguments: [["pair"], ["--port", "1"], ["doctor", "--fast"], ["doctor", "--json", "--commands"], ["update", "now"], ["--version", "x"]])
    func anythingElseIsRefusedRatherThanStartingASecondServer(arguments: [String]) {
        guard case .refused = GatewayCommand.parse(arguments) else {
            Issue.record("\(arguments) was not refused")
            return
        }
    }

    @Test func aRefusedCommandSaysSoOnStderrAndExitsWithTwo() async {
        let out = Collected()
        let err = Collected()
        let status = await GatewayCLI.run(.refused("unknown command \"pair\""), environment: [:], out: { out.add($0) }, err: { err.add($0) })
        #expect(status == 2)
        #expect(out.text.isEmpty)
        #expect(err.text.hasPrefix("voice-bridge: unknown command \"pair\""))
        #expect(err.text.contains("usage:"))
    }

    @Test func versionPrintsTheLineOnStdout() async {
        let out = Collected()
        let status = await GatewayCLI.run(.version, environment: [:], out: { out.add($0) }, err: { _ in })
        #expect(status == 0)
        #expect(out.text == "voice-bridge \(GatewayInfo.version)\n")
    }
}
