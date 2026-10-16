import Foundation
import SetupKit

extension Doctor {
    func software() -> [SetupCheck] {
        let prerequisites = [dockerCheck(), cdiCheck(), modelCheck(), imageCheck()]
        return (answersExternally ? prerequisites.map(vouched) : prerequisites) + [engineCheck()]
    }

    /// An engine someone else runs and that answers needs none of the local steps.
    private var answersExternally: Bool { !managed && engine == .ready }

    private func vouched(_ check: SetupCheck) -> SetupCheck {
        guard check.state != .ok else { return check }
        return SetupCheck(id: check.id, state: .ok, facts: ["mode": "external"])
    }

    private func dockerCheck() -> SetupCheck {
        var found = ["os": facts.os.id]
        if facts.docker == .ready { return SetupCheck(id: "voice.docker", state: .ok, facts: found) }
        found["problem"] = facts.docker.rawValue
        return SetupCheck(
            id: "voice.docker", state: .blocked, facts: found,
            detail: "Docker is not installed or this user cannot use it.", fix: FixCommands.docker(family: facts.os.family))
    }

    private func cdiCheck() -> SetupCheck {
        let found = ["toolkit": facts.toolkitInstalled ? "installed" : "missing"]
        if facts.cdi { return SetupCheck(id: "voice.cdi", state: .ok, facts: found) }
        return SetupCheck(
            id: "voice.cdi", state: .blocked, facts: found, detail: "The GPU is not described for containers yet.",
            fix: FixCommands.cdi)
    }

    private func modelCheck() -> SetupCheck {
        var found = ["bytes": "\(facts.model.bytes)", "needBytes": "\(VoiceRequirements.modelBytes)"]
        if facts.model.valid { return SetupCheck(id: "voice.model", state: .ok, facts: found) }
        let fix = VoiceRequirements.downloadModelFix
        if let job = jobs.open[fix] {
            return SetupCheck(
                id: "voice.model", state: .working, facts: found.merging(workingFacts(job)) { _, new in new },
                detail: "The voice model is downloading.")
        }
        found.merge(failureFacts(fix)) { _, new in new }
        let remaining = max(0, VoiceRequirements.modelBytes - facts.model.bytes)
        let minutes = max(1, Int((Double(VoiceRequirements.modelMinutes) * Double(remaining) / Double(VoiceRequirements.modelBytes)).rounded(.up)))
        return SetupCheck(
            id: "voice.model", state: .todo, facts: found, detail: "The voice model is not downloaded.",
            fix: SetupFix(id: fix, bytes: remaining, minutes: minutes))
    }

    private func imageCheck() -> SetupCheck {
        var found = ["needBytes": "\(VoiceRequirements.imageBytes)"]
        if let bytes = facts.imageBytes { return SetupCheck(id: "voice.image", state: .ok, facts: found.merging(["bytes": "\(bytes)"]) { _, new in new }) }
        let fix = VoiceRequirements.pullImageFix
        if let job = jobs.open[fix] {
            return SetupCheck(
                id: "voice.image", state: .working, facts: found.merging(workingFacts(job)) { _, new in new },
                detail: "The voice engine image is downloading.")
        }
        guard facts.dockerReady else {
            found["after"] = "voice.docker"
            return SetupCheck(id: "voice.image", state: .todo, facts: found, detail: "Docker comes first.")
        }
        found.merge(failureFacts(fix)) { _, new in new }
        return SetupCheck(
            id: "voice.image", state: .todo, facts: found, detail: "The voice engine image is not downloaded.",
            fix: SetupFix(id: fix, bytes: VoiceRequirements.imageBytes, minutes: VoiceRequirements.imageMinutes))
    }
}
