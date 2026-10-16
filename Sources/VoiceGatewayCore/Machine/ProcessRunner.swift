import Foundation

/// Runs real processes. The environment is the gateway's own unless a test hands in another, and a
/// bare executable name is looked up on that environment's `PATH`.
public struct ProcessRunner: CommandRunner {
    public let baseEnvironment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        baseEnvironment = environment
    }

    public func run(_ spec: CommandSpec) async -> CommandResult {
        #if os(Linux)
        switch launch(spec, mode: .collected) {
        case .failure(let failure):
            return .notLaunched(failure.reason)
        case .success(let process):
            let timer = spec.timeout.map { seconds in
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    process.markTimedOut()
                    process.cancel()
                }
            }
            let result = await withTaskCancellationHandler {
                await process.wait()
            } onCancel: {
                process.cancel()
            }
            timer?.cancel()
            return result
        }
        #else
        return .notLaunched("process control needs Linux")
        #endif
    }

    public func stream(_ spec: CommandSpec) -> any RunningCommand {
        #if os(Linux)
        switch launch(spec, mode: .merged) {
        case .failure(let failure): return FailedCommand(reason: failure.reason)
        case .success(let process): return process
        }
        #else
        return FailedCommand(reason: "process control needs Linux")
        #endif
    }

    #if os(Linux)
    private func launch(_ spec: CommandSpec, mode: SpawnedProcess.Mode) -> Result<SpawnedProcess, SpawnFailure> {
        let environment = baseEnvironment.merging(spec.environment) { _, new in new }
        guard let path = Executables.resolve(spec.executable, searchPath: environment["PATH"]) else {
            return .failure(SpawnFailure(reason: "\(spec.executable) was not found"))
        }
        return SpawnedProcess.launch(path: path, arguments: spec.arguments, environment: environment, mode: mode)
    }
    #endif
}

/// What `stream` returns when the process could not even start.
struct FailedCommand: RunningCommand {
    let reason: String

    var lines: AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func cancel() {}

    func wait() async -> CommandResult {
        .notLaunched(reason)
    }
}

enum Executables {
    static func resolve(_ name: String, searchPath: String?) -> String? {
        let fileManager = FileManager.default
        if name.contains("/") { return fileManager.isExecutableFile(atPath: name) ? name : nil }
        for directory in (searchPath ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                fileManager.isExecutableFile(atPath: candidate)
            {
                return candidate
            }
        }
        return nil
    }
}
