import Foundation
import Logging
import VoiceKit

/// `voice-probe run ...` and `voice-probe fake-nim ...`. Returns the process exit code.
public enum ProbeCLI {
    public static let usage = """
        usage:
          voice-probe run [--nim URL] --wav a.wav [--wav b.wav ...] [--gap-ms 1500] [--settle-ms 4000]
                          [--barge-in-ms N --interrupt-wav x.wav] [--soak-seconds N] [--json out.json]
          voice-probe fake-nim [--port 9100]

        WAV files must be 24 kHz mono 16-bit PCM. --nim defaults to $VOICE_NIM_URL, then
        ws://127.0.0.1:9000/v1/realtime.
        """

    public static func main(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else { return fail(usage) }
        do {
            switch command {
            case "run": return try await run(Array(arguments.dropFirst()))
            case "fake-nim": return try await fakeNIM(Array(arguments.dropFirst()))
            default: return fail(usage)
            }
        } catch {
            return fail("\(error)")
        }
    }

    struct Parsed {
        var values: [String: [String]] = [:]

        init(_ arguments: [String], allowed: Set<String>) throws {
            var index = 0
            while index < arguments.count {
                let key = arguments[index]
                guard allowed.contains(key), index + 1 < arguments.count else {
                    throw UsageError(message: "unknown or incomplete option \(key)\n\n\(ProbeCLI.usage)")
                }
                values[key, default: []].append(arguments[index + 1])
                index += 2
            }
        }

        func one(_ key: String) -> String? { values[key]?.last }
        func int(_ key: String) throws -> Int? {
            guard let text = one(key) else { return nil }
            guard let value = Int(text), value >= 0 else { throw UsageError(message: "\(key) needs a whole number, got \(text)") }
            return value
        }
    }

    struct UsageError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    static func options(_ arguments: [String]) throws -> (ProbeOptions, String?) {
        let parsed = try Parsed(
            arguments,
            allowed: ["--nim", "--wav", "--gap-ms", "--settle-ms", "--barge-in-ms", "--interrupt-wav", "--soak-seconds", "--json"])
        let paths = parsed.values["--wav"] ?? []
        guard !paths.isEmpty else { throw UsageError(message: "at least one --wav is needed\n\n\(usage)") }
        let url = parsed.one("--nim") ?? ProcessInfo.processInfo.environment["VOICE_NIM_URL"] ?? GatewayConfig.defaultNIMURL
        var options = ProbeOptions(nimURL: url, wavs: try paths.map { try WavFile.read(path: $0) })
        options.gapMs = try parsed.int("--gap-ms") ?? options.gapMs
        options.settleMs = try parsed.int("--settle-ms") ?? options.settleMs
        options.soakSeconds = try parsed.int("--soak-seconds")
        options.bargeInMs = try parsed.int("--barge-in-ms")
        if let path = parsed.one("--interrupt-wav") { options.interruptWav = try WavFile.read(path: path) }
        guard (options.bargeInMs == nil) == (options.interruptWav == nil) else {
            throw UsageError(message: "--barge-in-ms and --interrupt-wav go together")
        }
        return (options, parsed.one("--json"))
    }

    private static func run(_ arguments: [String]) async throws -> Int32 {
        let (options, jsonPath) = try options(arguments)
        let report = try await ProbeRunner.run(options: options)
        print(report.humanSummary())
        if let jsonPath {
            try Data(report.pretty().utf8).write(to: URL(fileURLWithPath: jsonPath))
            print("wrote \(jsonPath)")
        }
        return 0
    }

    private static func fakeNIM(_ arguments: [String]) async throws -> Int32 {
        let parsed = try Parsed(arguments, allowed: ["--port"])
        let server = FakeNIMServer(script: FakeNIMDemo.script)
        let port = await server.start(port: try parsed.int("--port") ?? 9100)
        print("fake NIM on \(server.url) (health at http://127.0.0.1:\(port)/v1/realtime/health), ctrl-c to stop")
        while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
        await server.stop()
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }
}
