import Foundation
import SetupKit
import Testing
@testable import VoiceGatewayCore

@Suite(.serialized)
struct NGCInstallTests {
    static let fixtureSHA = "f16d05ec6b29248d2c61adb1e9263f78e4f7bace1b955014a2d17872cfe4064d"

    static func package(sha: String = fixtureSHA) -> @Sendable (String) -> NGCRelease.Package? {
        { _ in NGCRelease.Package(file: "ngccli_test.zip", sha256: sha) }
    }

    func installDownloadTools(_ harness: JobHarness, curlStatus: Int = 0) {
        harness.bin.install(
            "curl",
            """
            echo "$@" > '\(harness.bin.url.path)/curl.args'
            [ \(curlStatus) -ne 0 ] && { echo 'curl: (6) Could not resolve host' >&2; exit \(curlStatus); }
            while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
            printf fixture > "$out"
            """)
        harness.bin.install(
            "unzip",
            """
            echo "$@" > '\(harness.bin.url.path)/unzip.args'
            while [ $# -gt 0 ]; do [ "$1" = "-d" ] && dir="$2"; shift; done
            mkdir -p "$dir/ngc-cli"
            printf '#!/bin/sh\\nexit 0\\n' > "$dir/ngc-cli/ngc"
            """)
    }

    func ngcRuns(_ harness: JobHarness) -> Bool {
        FileManager.default.fileExists(atPath: harness.root.paths.ngcDir.appendingPathComponent("ngc-cli/ngc").path)
    }

    @Test func theCLIIsDownloadedCheckedAgainstThePinnedDigestAndThenUsed() async throws {
        let harness = JobHarness(ngcPackage: Self.package())
        installDownloadTools(harness)
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        let done = await harness.settle(job)
        #expect(done?.state == .failed)
        #expect(done?.facts["reason"] == "incomplete")
        #expect(ngcRuns(harness))
        let curl = try String(contentsOf: harness.bin.url.appendingPathComponent("curl.args"), encoding: .utf8)
        #expect(curl.contains("https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions/\(NGCRelease.version)/files/ngccli_test.zip"))
        #expect(!FileManager.default.fileExists(atPath: harness.root.paths.ngcDir.appendingPathComponent("ngccli_test.zip").path))
    }

    @Test func aDownloadThatDoesNotMatchTheDigestIsRefusedAndDeleted() async throws {
        let harness = JobHarness(ngcPackage: Self.package(sha: String(repeating: "a", count: 64)))
        installDownloadTools(harness)
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        let done = await harness.settle(job)
        #expect(done?.state == .failed)
        #expect(done?.failure == "other")
        #expect(done?.facts["reason"] == "checksum")
        #expect(done?.facts["expected"] == String(repeating: "a", count: 64))
        #expect(done?.facts["actual"] == Self.fixtureSHA)
        #expect(!ngcRuns(harness))
        #expect(!FileManager.default.fileExists(atPath: harness.root.paths.ngcDir.appendingPathComponent("ngccli_test.zip").path))
        #expect(!FileManager.default.fileExists(atPath: harness.bin.url.appendingPathComponent("unzip.args").path))
    }

    @Test func aDownloadThatCannotReachNVIDIAIsANetworkFailure() async throws {
        let harness = JobHarness(ngcPackage: Self.package())
        installDownloadTools(harness, curlStatus: 6)
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        let done = await harness.settle(job)
        #expect(done?.failure == "network")
        #expect(done?.facts["tail"]?.contains("Could not resolve host") == true)
    }

    @Test func aCLIAlreadyOnThePathIsUsedAsItIs() async throws {
        let harness = JobHarness(ngcPackage: Self.package())
        installDownloadTools(harness)
        harness.installNGC(SetupJobsTests.ngcScript(harness: harness))
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        #expect(await harness.settle(job)?.state == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: harness.bin.url.appendingPathComponent("curl.args").path))
        #expect(!ngcRuns(harness))
    }

    @Test func aMachineNVIDIAHasNoCLIForIsAClearFailure() async throws {
        let harness = JobHarness(ngcPackage: { _ in nil })
        installDownloadTools(harness)
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        let done = await harness.settle(job)
        #expect(done?.failure == "other")
        #expect(done?.facts["reason"] == "unsupportedMachine")
    }

    @Test func theNGCKeyIsPassedOnUnderTheNameTheCLIReads() async throws {
        let harness = JobHarness(gatewayEnvironment: ["NGC_API_KEY": "nvapi-test"])
        harness.installNGC("echo \"$NGC_CLI_API_KEY\" > '\(harness.bin.url.path)/key'\nexit 1")
        let job = try await harness.jobs.start(fix: "voice.downloadModel")
        _ = await harness.settle(job)
        let key = try String(contentsOf: harness.bin.url.appendingPathComponent("key"), encoding: .utf8)
        #expect(key == "nvapi-test\n")
    }

    @Test func theShippedDigestsAreTheOnesNVIDIAPublishes() {
        #expect(NGCRelease.package(machine: "x86_64\n")?.sha256 == "58bc4d7b6901551a095ce5a43a0065b1c22d5eaf1a164d40029ee3fda11ccd47")
        #expect(NGCRelease.package(machine: "aarch64")?.sha256 == "5c18c5d14ad9e4b8c8ac0b5c596cd4ed33c1e4a3f2bd93f851eb974a6f3f6847")
        #expect(NGCRelease.package(machine: "x86_64")?.url == "https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions/4.34.10/files/ngccli_linux.zip")
        #expect(NGCRelease.package(machine: "riscv64") == nil)
    }
}
