import Foundation

/// `~/.config/voice-bridge.env`, the file the service reads its `VOICE_*` settings from. The commands
/// that run by hand read it too, so `voice-bridge doctor` judges the machine the way the service sees it.
public enum EnvFile {
    public static let defaultName = ".config/voice-bridge.env"

    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            values[key] = unquote(String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
        }
        return values
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    public static func path(environment: [String: String]) -> String {
        if let explicit = environment["VOICE_ENV_FILE"], !explicit.isEmpty { return explicit }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return "\(home)/\(defaultName)"
    }

    /// The environment of a hand-run command: the file's settings under whatever is set for real.
    public static func layered(over environment: [String: String]) -> [String: String] {
        guard let text = try? String(contentsOfFile: path(environment: environment), encoding: .utf8) else { return environment }
        return parse(text).merging(environment) { _, real in real }
    }
}
