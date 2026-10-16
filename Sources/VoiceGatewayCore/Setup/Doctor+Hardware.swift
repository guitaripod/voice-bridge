import Foundation
import SetupKit

extension Doctor {
    enum Hardware {
        case fine([SetupCheck])
        case unsupported([SetupCheck])
    }

    func hardware() -> Hardware {
        guard let gpu = facts.gpu else {
            return .unsupported([
                SetupCheck(id: "voice.gpu", state: .unavailable, detail: "No NVIDIA GPU was found on this machine."),
                SetupCheck(id: "voice.vram", state: .unavailable),
            ])
        }
        let name = SetupCheck(id: "voice.gpu", state: .ok, facts: ["name": gpu.name])
        var vramFacts = ["needMB": "\(VoiceRequirements.freeVRAMMB)"]
        guard let total = gpu.totalMB else {
            return .unsupported([
                name,
                SetupCheck(
                    id: "voice.vram", state: .unavailable, facts: vramFacts,
                    detail: "The card's memory size could not be read."),
            ])
        }
        vramFacts["totalMB"] = "\(total)"
        guard total >= VoiceRequirements.minimumCardMB else {
            return .unsupported([
                name,
                SetupCheck(
                    id: "voice.vram", state: .unavailable, facts: vramFacts,
                    detail: "The voice model needs a card with \(VoiceRequirements.minimumCardMB / 1_000) GB; this one has \(total / 1_000) GB."),
            ])
        }
        return .fine([name, SetupCheck(id: "voice.vram", state: .ok, facts: vramFacts)])
    }
}
