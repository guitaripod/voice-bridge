import Foundation
import SetupKit

extension Doctor {
    func engineCheck() -> SetupCheck {
        let mode = ["mode": managed ? "managed" : "external"]
        if managed, let missing = firstMissingPrerequisite() {
            return SetupCheck(
                id: "voice.engine", state: .todo, facts: mode.merging(["after": missing]) { _, new in new },
                detail: "The voice engine waits for the steps above.")
        }
        switch engine {
        case .ready:
            return SetupCheck(id: "voice.engine", state: .ok, facts: mode.merging(["state": "running"]) { _, new in new })
        case .stopped:
            return SetupCheck(
                id: "voice.engine", state: .ok,
                facts: mode.merging(["state": "stopped", "freeMB": "\(facts.gpu?.freeMB ?? 0)", "needMB": "\(VoiceRequirements.freeVRAMMB)"]) { _, new in new },
                detail: "The voice engine starts when a call needs it.")
        case .loading(let progress):
            var found = mode.merging(["state": "loading"]) { _, new in new }
            if let progress { found["progress"] = String(format: "%.2f", progress) }
            return SetupCheck(id: "voice.engine", state: .working, facts: found, detail: "The voice engine is loading.")
        case .busy(let free, let need, let holders):
            return SetupCheck(
                id: "voice.engine", state: .blocked,
                facts: mode.merging(["state": "busy", "freeMB": "\(free)", "needMB": "\(need)", "holders": holders.joined(separator: ",")]) { _, new in new },
                detail: "The GPU is held by another job.")
        case .down(let reason):
            return SetupCheck(
                id: "voice.engine", state: .blocked,
                facts: mode.merging(["state": "down", "reason": reason]) { _, new in new }.merging(failureFacts()) { _, new in new },
                detail: "The voice engine is not running.")
        case .needsSetup:
            return SetupCheck(
                id: "voice.engine", state: .todo, facts: mode.merging(["state": "needsSetup"]) { _, new in new },
                detail: "The voice engine waits for the steps above.")
        }
    }

    private func failureFacts() -> [String: String] {
        guard let failure else { return [:] }
        return failure.facts.merging(["failure": failure.id]) { _, new in new }
    }

    private func firstMissingPrerequisite() -> String? {
        if !facts.dockerReady { return "voice.docker" }
        if !facts.cdi { return "voice.cdi" }
        if !facts.model.valid { return "voice.model" }
        if !facts.imagePresent { return "voice.image" }
        return nil
    }
}
