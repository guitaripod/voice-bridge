import Foundation
import VoiceKit

/// A NIM socket with the voice session already configured: `session.update` with the persona and
/// the three tools has been sent. The gateway and `voice-probe` open sessions the same way.
public struct NIMSession: Sendable {
    public let connection: any NIMConnection

    public static func open(
        connector: any NIMConnector, url: String, timeout: Double,
        instructions: String = VoiceTools.systemPrompt, tools: [VoiceTool] = VoiceTools.all
    ) async throws -> NIMSession {
        let connection = try await connector.connect(url: url, timeout: timeout)
        connection.send(NIMMessages.sessionUpdate(instructions: instructions, tools: tools))
        return NIMSession(connection: connection)
    }

    public var events: AsyncStream<NIMInbound> { connection.events }

    /// Sends microphone audio in the chunk size the NIM prefers, splitting anything larger.
    public func appendAudio(_ pcm: Data) {
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(offset + VoiceWire.preferredChunkBytes, pcm.endIndex)
            connection.send(NIMMessages.appendAudio(pcm[offset..<end]))
            offset = end
        }
    }

    public func answer(callID: String, output: String) {
        connection.send(NIMMessages.functionCallOutput(callID: callID, output: output))
    }

    public func close() async {
        connection.send(NIMMessages.sessionClose())
        await connection.close()
    }
}
