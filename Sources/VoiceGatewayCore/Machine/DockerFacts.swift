import Foundation

enum DockerState: String, Sendable, Equatable {
    case missing, denied, stopped, ready

    /// `docker version` asks the daemon, so its failure says which way docker is unusable.
    static func interpret(_ result: CommandResult) -> DockerState {
        guard result.launched else { return .missing }
        if result.succeeded { return .ready }
        let text = (result.error + result.output).lowercased()
        if text.contains("permission denied") { return .denied }
        return .stopped
    }
}

enum ContainerState: Sendable, Equatable {
    case absent
    case running
    case other(String)

    var exists: Bool { self != .absent }
}

enum DockerPS {
    static let format = "{{.Names}}|{{.State}}|{{.Status}}"

    /// `docker ps` filters by substring, so the name is matched exactly here: a container that merely
    /// contains ours is never ours.
    static func state(of name: String, in output: String) -> ContainerState {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, fields[0] == name else { continue }
            return fields[1] == "running" ? .running : .other(fields[1])
        }
        return .absent
    }
}
