import Foundation

public struct CommandSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var timeout: Double?

    public init(_ executable: String, _ arguments: [String] = [], environment: [String: String] = [:], timeout: Double? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

public struct CommandResult: Sendable, Equatable {
    public var launched: Bool
    public var status: Int32
    public var output: String
    public var error: String
    public var timedOut: Bool

    public init(launched: Bool = true, status: Int32 = 0, output: String = "", error: String = "", timedOut: Bool = false) {
        self.launched = launched
        self.status = status
        self.output = output
        self.error = error
        self.timedOut = timedOut
    }

    public static func notLaunched(_ reason: String) -> CommandResult {
        CommandResult(launched: false, status: 127, error: reason)
    }

    public var succeeded: Bool { launched && !timedOut && status == 0 }

    public func tail(_ count: Int = 8) -> [String] {
        let text = error.isEmpty ? output : output + "\n" + error
        return text.split(whereSeparator: \.isNewline).suffix(count).map(String.init)
    }
}

/// A command that is still running. `lines` carries stdout and stderr merged, one entry per line (a
/// carriage return also ends a line, because progress bars use it) and finishes when the process and
/// its pipes are done. `wait` returns the result once, with the output left to whoever read `lines`.
public protocol RunningCommand: Sendable {
    var lines: AsyncStream<String> { get }
    func cancel()
    func wait() async -> CommandResult
}

/// Every command the gateway runs on its machine goes through this, so a test can stand in for the
/// whole machine.
public protocol CommandRunner: Sendable {
    func run(_ spec: CommandSpec) async -> CommandResult
    func stream(_ spec: CommandSpec) -> any RunningCommand
}
