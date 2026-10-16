import Foundation
import VoiceGatewayCore

/// A directory of fake executables that stands first on the `PATH` of a real `ProcessRunner`.
final class FakeBin: Sendable {
    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fakebin-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func install(_ name: String, _ script: String) {
        let file = url.appendingPathComponent(name)
        try? "#!/bin/sh\n\(script)\n".write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func runner(extra: [String: String] = [:]) -> ProcessRunner {
        var environment = ["PATH": "\(url.path):/usr/bin:/bin", "HOME": url.path]
        environment.merge(extra) { _, new in new }
        return ProcessRunner(environment: environment)
    }
}
