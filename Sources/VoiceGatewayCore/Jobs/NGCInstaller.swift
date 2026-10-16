import Foundation

/// Finds the NGC CLI or installs NVIDIA's own build of it into the gateway's directory: download the
/// zip, check its SHA-256 against the pinned value, unpack. A CLI already on the machine is used as it is.
struct NGCInstaller: Sendable {
    let environment: JobEnvironment

    private var runner: any CommandRunner { environment.runner }
    private var installed: URL { environment.paths.ngcDir.appendingPathComponent("ngc-cli/ngc") }

    func ensure(_ context: JobContext) async -> Result<String, JobFailure> {
        if FileManager.default.isExecutableFile(atPath: installed.path) { return .success(installed.path) }
        if await runner.run(CommandSpec("ngc", ["--version"], timeout: 30)).succeeded { return .success("ngc") }
        await context.progress(step: "ngc")
        return await install(context)
    }

    private func install(_ context: JobContext) async -> Result<String, JobFailure> {
        let machine = await runner.run(CommandSpec("uname", ["-m"], timeout: 10))
        guard let package = environment.ngcPackage(machine.output) else {
            return .failure(.other("unsupportedMachine", tail: [machine.output.trimmingCharacters(in: .whitespacesAndNewlines)]))
        }
        let directory = environment.paths.ngcDir
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zip = directory.appendingPathComponent(package.file)
        if let failure = await download(package, to: zip) { return .failure(failure) }
        if let failure = await verify(zip, expected: package.sha256) { return .failure(failure) }
        return await unpack(zip, directory: directory)
    }

    private func download(_ package: NGCRelease.Package, to zip: URL) async -> JobFailure? {
        let result = await runner.run(
            CommandSpec("curl", ["-fL", "--retry", "3", "--retry-delay", "2", "-o", zip.path, package.url], timeout: 1_800))
        if result.succeeded { return nil }
        if !result.launched { return .other("curlMissing") }
        try? FileManager.default.removeItem(at: zip)
        let networkCodes: Set<Int32> = [5, 6, 7, 28, 35, 52, 55, 56]
        let id = networkCodes.contains(result.status) ? JobFailure.network : JobFailure.other
        return JobFailure(id: id, facts: ["reason": "ngcDownload", "status": "\(result.status)"].merging(JobFailure.tailFacts(result.tail(4))) { _, new in new })
    }

    private func verify(_ zip: URL, expected: String) async -> JobFailure? {
        let result = await runner.run(CommandSpec("sha256sum", [zip.path], timeout: 120))
        let actual = result.output.split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() } ?? ""
        if result.succeeded, actual == expected.lowercased() { return nil }
        try? FileManager.default.removeItem(at: zip)
        return JobFailure(id: JobFailure.other, facts: ["reason": "checksum", "expected": expected, "actual": actual])
    }

    private func unpack(_ zip: URL, directory: URL) async -> Result<String, JobFailure> {
        let unzip = await runner.run(CommandSpec("unzip", ["-o", "-q", zip.path, "-d", directory.path], timeout: 300))
        guard unzip.succeeded else { return .failure(.other("unzip", tail: unzip.tail(4))) }
        _ = await runner.run(CommandSpec("chmod", ["u+x", installed.path], timeout: 10))
        try? FileManager.default.removeItem(at: zip)
        guard FileManager.default.isExecutableFile(atPath: installed.path) else { return .failure(.other("ngcMissingAfterUnzip")) }
        return .success(installed.path)
    }
}
