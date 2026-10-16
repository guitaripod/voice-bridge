import Foundation

/// Where the gateway keeps what it downloads and what it remembers, and the system files it reads.
public struct MachinePaths: Sendable, Equatable {
    public var modelDir: URL
    public var jobsDir: URL
    public var ngcDir: URL
    public var osRelease: URL
    public var cdiDirectories: [URL]

    public init(
        home: URL, modelDir: URL? = nil, osRelease: URL = URL(fileURLWithPath: "/etc/os-release"),
        cdiDirectories: [URL] = [URL(fileURLWithPath: "/etc/cdi"), URL(fileURLWithPath: "/var/run/cdi")]
    ) {
        let share = home.appendingPathComponent(".local/share/voice-bridge", isDirectory: true)
        self.modelDir = modelDir ?? share.appendingPathComponent("model", isDirectory: true)
        ngcDir = share.appendingPathComponent("ngc", isDirectory: true)
        jobsDir = home.appendingPathComponent(".local/state/voice-bridge/jobs", isDirectory: true)
        self.osRelease = osRelease
        self.cdiDirectories = cdiDirectories
    }

    public init(environment: [String: String]) {
        let home = URL(fileURLWithPath: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(), isDirectory: true)
        let model = environment["VOICE_MODEL_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        self.init(home: home, modelDir: model)
    }
}
