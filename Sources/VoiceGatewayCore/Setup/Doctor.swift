import Foundation
import SetupKit

/// What the doctor needs to know about jobs: the ones still open, and how the last attempt at a fix ended.
struct JobsView: Sendable, Equatable {
    var open: [String: SetupJob] = [:]
    var lastFailed: [String: SetupJob] = [:]

    var newestOpen: SetupJob? { open.values.max { $0.startedAt < $1.startedAt } }
}

/// Turns the facts of a machine into the `SetupReport` for voice. It is pure: the same facts, engine
/// status and jobs always give the same report, so every state can be written down as a test.
struct Doctor: Sendable {
    let facts: MachineFacts
    let engine: EngineStatus
    let managed: Bool
    let jobs: JobsView
    let version: String

    func report() -> SetupReport {
        var checks: [SetupCheck]
        var available = true
        switch hardware() {
        case .fine(let found):
            checks = found
            checks += software()
        case .unsupported(let found):
            available = false
            checks = found + Self.waiting.map { SetupCheck(id: $0, state: .unavailable) }
        }
        checks.append(SetupCheck(id: "voice.gateway", state: .ok, facts: ["version": version]))
        return SetupReport(
            capability: VoiceRequirements.capability, available: available, ready: available && checks.allSatisfy { $0.state == .ok },
            checks: checks, job: jobs.newestOpen)
    }

    static let waiting = ["voice.docker", "voice.cdi", "voice.model", "voice.image", "voice.engine"]

    func failureFacts(_ fix: String) -> [String: String] {
        guard let failed = jobs.lastFailed[fix], let failure = failed.failure else { return [:] }
        return ["lastFailure": failure, "lastJob": failed.id]
    }

    func workingFacts(_ job: SetupJob) -> [String: String] {
        var facts = ["job": job.id]
        if let fraction = job.fraction { facts["progress"] = String(format: "%.2f", fraction) }
        return facts
    }
}
