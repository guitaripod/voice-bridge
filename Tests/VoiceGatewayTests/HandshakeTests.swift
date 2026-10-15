import Foundation
import Testing
import VoiceGatewayCore
import VoiceKit

@Suite(.serialized)
struct HandshakeTests {
    @Test func helloIsAnsweredWithReadyAndListening() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        let client = try await harness.call()
        let ready = client.messages.first { if case .ready = $0 { true } else { false } }
        #expect(ready == .ready(.init(gateway: GatewayInfo.version, model: GatewayInfo.modelName)))
        let listening = await client.waitFor { if case .phase(.listening, _) = $0 { true } else { false } }
        #expect(listening != nil)
        let update = await harness.nim.sessions.first?.message("session.update")
        #expect(update != nil)
        await client.close()
    }
}
