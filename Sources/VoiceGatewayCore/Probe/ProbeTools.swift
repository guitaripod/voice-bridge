import Foundation

/// Reads the tools of a probe run from a file, in the shape the NIM takes them: a JSON array of
/// `{"type":"function","name":...,"description":...,"ack_messages":[...],"parameters":{...}}`.
public enum ProbeTools {
    public struct Invalid: Error, CustomStringConvertible {
        public var description: String
    }

    public static func parse(_ text: String) throws -> [VoiceTool] {
        guard let value = JSONValue.parse(text), case .array(let items) = value else {
            throw Invalid(description: "the tools file must hold a JSON array of tool objects")
        }
        return try items.enumerated().map { index, item in
            guard let name = item["name"]?.string, !name.isEmpty else {
                throw Invalid(description: "tool \(index) has no name")
            }
            var acks: [String] = []
            if case .array(let list)? = item["ack_messages"] { acks = list.compactMap(\.string) }
            return VoiceTool(
                name: name, description: item["description"]?.string ?? "", ackMessages: acks,
                parameters: item["parameters"] ?? .object(["type": .string("object"), "properties": .object([:])]))
        }
    }
}
