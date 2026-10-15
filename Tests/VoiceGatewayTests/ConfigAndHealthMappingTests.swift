import Foundation
import Testing
@testable import VoiceGatewayCore

struct ConfigAndHealthMappingTests {
    @Test func defaults() {
        let config = GatewayConfig(environment: [:])
        #expect(config.port == 4102)
        #expect(config.nimURL == "ws://127.0.0.1:9000/v1/realtime")
        #expect(config.password == nil)
        #expect(config.logLevel == .info)
    }

    @Test func environmentOverrides() {
        let config = GatewayConfig(environment: [
            "VOICE_PORT": "4999", "VOICE_NIM_URL": "ws://gpu:9000/v1/realtime", "VOICE_PASSWORD": "s3",
            "VOICE_LOG_LEVEL": "DEBUG",
        ])
        #expect(config.port == 4999)
        #expect(config.nimURL == "ws://gpu:9000/v1/realtime")
        #expect(config.password == "s3")
        #expect(config.logLevel == .debug)
    }

    @Test func junkFallsBackToDefaults() {
        let config = GatewayConfig(environment: ["VOICE_PORT": "abc", "VOICE_PASSWORD": "", "VOICE_LOG_LEVEL": "loud"])
        #expect(config.port == 4102)
        #expect(config.password == nil)
        #expect(config.logLevel == .info)
    }

    @Test func healthURLIsDerivedFromTheSocketURL() {
        #expect(HTTPNIMHealthProbe.healthURL(for: "ws://127.0.0.1:9000/v1/realtime")?.absoluteString == "http://127.0.0.1:9000/v1/realtime/health")
        #expect(HTTPNIMHealthProbe.healthURL(for: "wss://gpu.example/v1/realtime/")?.absoluteString == "https://gpu.example/v1/realtime/health")
    }

    @Test func probeResultsFollowTheDocumentedSignals() {
        let ready = Data(#"{"triton_status":"ready"}"#.utf8)
        #expect(NIMProbeResult.interpret(status: 200, body: ready) == .ready)
        if case .loading = NIMProbeResult.interpret(status: 503, body: Data()) {} else { Issue.record("503 should be loading") }
        if case .loading = NIMProbeResult.interpret(status: 200, body: Data(#"{"triton_status":"starting"}"#.utf8)) {} else { Issue.record("not ready should be loading") }
        if case .down = NIMProbeResult.interpret(status: 500, body: Data()) {} else { Issue.record("500 should be down") }
    }

    @Test func bearerComparison() {
        #expect(BearerAuth<TestContext>.matches(header: "Bearer secret", password: "secret"))
        #expect(!BearerAuth<TestContext>.matches(header: "Bearer secre", password: "secret"))
        #expect(!BearerAuth<TestContext>.matches(header: "Bearer secrett", password: "secret"))
        #expect(!BearerAuth<TestContext>.matches(header: "Basic secret", password: "secret"))
        #expect(!BearerAuth<TestContext>.matches(header: "secret", password: "secret"))
    }
}

import Hummingbird

typealias TestContext = BasicRequestContext
