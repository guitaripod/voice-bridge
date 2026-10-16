import Foundation

/// What the voice engine is doing, as the gateway reports it on `/health` and in the checklist.
enum EngineStatus: Sendable, Equatable {
    case ready
    case loading(progress: Double?)
    case stopped
    case needsSetup
    case busy(freeMB: Int, needMB: Int, holders: [String])
    case down(reason: String)

    /// `loading`: the manager has a start in flight and knows how far along it is.
    /// `failure`: why the last start did not work, while it is still worth saying.
    static func derive(facts: MachineFacts, managed: Bool, loading: Double?, failure: String?) -> EngineStatus {
        if let loading { return .loading(progress: loading) }
        if facts.nim == .ready { return .ready }
        if facts.container == .running { return .loading(progress: nil) }
        guard managed else { return externalStatus(facts.nim) }
        if case .other(let state) = facts.container { return .down(reason: failure ?? "the container is \(state)") }
        guard facts.setupComplete else { return .needsSetup }
        if let failure { return .down(reason: failure) }
        let free = facts.gpu?.freeMB ?? 0
        guard free >= VoiceRequirements.freeVRAMMB else {
            return .busy(freeMB: free, needMB: VoiceRequirements.freeVRAMMB, holders: facts.gpu?.holderNames ?? [])
        }
        return .stopped
    }

    private static func externalStatus(_ nim: NIMProbeResult) -> EngineStatus {
        switch nim {
        case .ready: .ready
        case .loading: .loading(progress: nil)
        case .down(let detail): .down(reason: detail)
        }
    }
}
