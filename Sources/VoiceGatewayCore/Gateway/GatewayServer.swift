import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

/// Runs one gateway app per address in the bind plan under a single service group, so a signal
/// stops all of them together.
public enum GatewayServer {
    public static func run(gateway: Gateway, plan: BindPlan) async throws {
        let logger = gateway.logger
        for note in plan.notes { logger.info("\(note)") }
        var services: [ServiceGroupConfiguration.ServiceConfiguration] = []
        for host in plan.hosts {
            let app = GatewayApp.make(
                gateway: gateway, host: host, port: gateway.config.port,
                onServerRunning: { _ in logger.info("voice-bridge \(GatewayInfo.version) listening on \(host):\(gateway.config.port)") })
            services.append(.init(service: app))
        }
        let group = ServiceGroup(
            configuration: .init(
                services: services, gracefulShutdownSignals: [.sigterm, .sigint], logger: logger))
        try await group.run()
    }
}
