import Foundation

/// Where the gateway listens: loopback always, plus this machine's tailnet IPv4 when tailscale
/// answered with one. Nothing here can produce a wildcard address.
public struct BindPlan: Sendable, Equatable {
    public static let loopback = "127.0.0.1"

    public var hosts: [String]
    public var notes: [String]

    public static func make(tailscaleOutput: String?) -> BindPlan {
        guard let output = tailscaleOutput else {
            return BindPlan(hosts: [loopback], notes: ["tailscale not available, listening on loopback only"])
        }
        let first = output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let octets = ipv4Octets(first) else {
            return BindPlan(
                hosts: [loopback], notes: ["tailscale ip -4 gave no IPv4 address, listening on loopback only"])
        }
        guard isTailnetRange(octets) else {
            return BindPlan(
                hosts: [loopback],
                notes: ["\(first) is outside the tailnet range 100.64.0.0/10, listening on loopback only"])
        }
        return BindPlan(hosts: [loopback, first], notes: ["listening on loopback and tailnet address \(first)"])
    }

    static func ipv4Octets(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCIIDigit), let value = Int(part), value <= 255
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    static func isTailnetRange(_ octets: [Int]) -> Bool {
        octets[0] == 100 && (64...127).contains(octets[1])
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
