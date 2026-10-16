import Foundation

/// A release number such as `0.2.1`: digits and single dots, nothing else. It is the same shape the
/// installer accepts from `latest.txt`, so a page that is not a version never compares as one.
public struct ReleaseVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == pieces.count else { return nil }
        parts = numbers
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let width = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<width {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
