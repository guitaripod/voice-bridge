import Foundation

enum DiskSpace {
    /// Free megabytes on the filesystem that holds `path`, or on the nearest parent that exists.
    static func freeMB(at path: URL, runner: any CommandRunner) async -> Int? {
        var existing = path
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            existing = existing.deletingLastPathComponent()
        }
        let result = await runner.run(CommandSpec("df", ["-Pk", existing.path], timeout: 10))
        return result.succeeded ? parse(result.output) : nil
    }

    static func parse(_ output: String) -> Int? {
        guard let last = output.split(whereSeparator: \.isNewline).last else { return nil }
        let fields = last.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4, let kilobytes = Int(fields[3]) else { return nil }
        return kilobytes / 1_024
    }
}
