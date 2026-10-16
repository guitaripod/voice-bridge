import Foundation
import SetupKit
import VoiceKit

/// Whether the running gateway may be restarted now. A restart ends a call, kills a download's
/// processes and drops an engine load that is in flight, so anything but a gateway that is idle, or not
/// running at all, is a reason to wait.
enum RestartVerdict: Equatable {
    case safe
    case notRunning
    case wait(String)
    case unknown(String)
}

enum UpdateGuard {
    static func verdict(health: GatewayAnswer<VoiceHealth>, setup: () async -> GatewayAnswer<[SetupReport]>) async -> RestartVerdict {
        switch health {
        case .notRunning:
            return .notRunning
        case .unreadable(let reason):
            return .unknown(reason)
        case .answered(let answer):
            if answer.calls > 0 { return .wait("a call is in progress") }
            if answer.engine == .loading { return .wait("the voice engine is loading") }
        }
        switch await setup() {
        case .notRunning:
            return .notRunning
        case .unreadable(let reason):
            return .unknown(reason)
        case .answered(let reports):
            return reports.lazy.compactMap(busy).first.map(RestartVerdict.wait) ?? .safe
        }
    }

    private static func busy(_ report: SetupReport) -> String? {
        if let working = report.checks.first(where: { $0.state == .working }) { return reason(working.id) }
        return report.job.map { reason($0.fix) }
    }

    private static func reason(_ id: String) -> String {
        switch id {
        case VoiceRequirements.downloadModelFix, "voice.model": "the voice model is downloading"
        case VoiceRequirements.pullImageFix, "voice.image": "the voice engine image is downloading"
        case "voice.engine": "the voice engine is loading"
        default: "a setup step is running"
        }
    }
}
