import Foundation

enum OSFamily: String, Sendable, Equatable {
    case arch, debian, other
}

struct OSRelease: Sendable, Equatable {
    var id: String
    var family: OSFamily

    static let unknown = OSRelease(id: "unknown", family: .other)

    static func parse(_ text: String) -> OSRelease {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }
        let id = (values["ID"] ?? "unknown").lowercased()
        let related = ([id] + (values["ID_LIKE"] ?? "").lowercased().split(separator: " ").map(String.init))
        if related.contains("arch") { return OSRelease(id: id, family: .arch) }
        if related.contains("debian") || related.contains("ubuntu") { return OSRelease(id: id, family: .debian) }
        return OSRelease(id: id, family: .other)
    }
}
