import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import VoiceKit

/// The HTTP and WebSocket surface: `GET /health`, `GET /update`, `ws /call` and the `/setup` routes, all behind the bearer password.
public enum GatewayApp {
    public static func make(
        gateway: Gateway, host: String, port: Int,
        onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in }
    ) -> some ApplicationProtocol {
        let router = Router(context: BasicRequestContext.self)
        router.add(middleware: BearerAuth<BasicRequestContext>(password: gateway.config.password))
        router.get(RouterPath(VoiceWire.healthPath)) { _, _ -> Response in
            let health = await gateway.health()
            return try jsonResponse(health)
        }
        router.get(RouterPath(UpdateWire.path)) { _, _ -> Response in
            try jsonResponse(await gateway.updates.info())
        }
        if let machine = gateway.machine { SetupRoutes.add(to: router, services: machine) }

        let socketRouter = Router(context: BasicWebSocketRequestContext.self)
        socketRouter.add(middleware: BearerAuth<BasicWebSocketRequestContext>(password: gateway.config.password))
        socketRouter.ws(RouterPath(VoiceWire.callPath)) { inbound, outbound, _ in
            await gateway.serveCall(inbound: inbound, outbound: outbound)
        }

        return Application(
            router: router,
            server: .http1WebSocketUpgrade(
                webSocketRouter: socketRouter,
                configuration: .init(ws: .init(maxFrameSize: VoiceWire.maxChunkBytes * 4))),
            configuration: .init(address: .hostname(host, port: port), serverName: "voice-bridge"),
            onServerRunning: onServerRunning,
            logger: gateway.logger)
    }

    static func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return Response(
            status: .ok, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
