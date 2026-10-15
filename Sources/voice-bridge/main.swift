import Foundation
import Logging
import VoiceGatewayCore

signal(SIGPIPE, SIG_IGN)

let config = GatewayConfig(environment: ProcessInfo.processInfo.environment)
var logger = Logger(label: "voice-bridge")
logger.logLevel = config.logLevel

let plan = BindPlan.make(tailscaleOutput: TailscaleAddress.resolve())
let gateway = Gateway(config: config, logger: logger)

do {
    try await GatewayServer.run(gateway: gateway, plan: plan)
} catch {
    logger.critical("voice-bridge stopped", metadata: ["error": "\(error)"])
    exit(1)
}
