import Foundation
import SetupKit

/// The `SetupReport` for voice in plain terminal words: the hardware verdict first, then one line per
/// check with a mark, the command that needs administrator rights, or the note that Tailscode does
/// the step. The words come from the check ids and facts, never from the English `detail`.
struct DoctorText: Sendable {
    var unicode = true

    private static let hardwareIDs: Set<String> = ["voice.gpu", "voice.vram", "voice.gateway"]

    func render(_ report: SetupReport) -> String {
        var lines = [verdict(report), ""]
        for check in report.checks where report.available || Self.hardwareIDs.contains(check.id) {
            lines += rows(for: check)
        }
        lines += ["", closing(report)]
        return lines.joined(separator: "\n") + "\n"
    }

    func commands(_ report: SetupReport) -> [String] {
        var seen = Set<String>()
        return report.checks.compactMap { $0.fix }.filter { $0.kind == .command }.compactMap(\.command).filter { seen.insert($0).inserted }
    }

    private func check(_ report: SetupReport, _ id: String) -> SetupCheck? {
        report.checks.first { $0.id == id }
    }

    static func gigabytes(mebibytes: Int) -> Int { (mebibytes + 512) / 1_024 }

    static func gigabytes(bytes: Int64) -> Int { Int((Double(bytes) / 1_000_000_000).rounded()) }

    private static func card(_ name: String) -> String {
        name.lowercased().hasPrefix("nvidia") ? "an \(name)" : "an NVIDIA \(name)"
    }

    private func verdict(_ report: SetupReport) -> String {
        let gpu = check(report, "voice.gpu")
        let total = check(report, "voice.vram")?.facts["totalMB"].flatMap(Int.init)
        let name = gpu?.facts["name"]
        if report.available, let name, let total {
            return "This machine has \(Self.card(name)) with \(Self.gigabytes(mebibytes: total)) GB: voice calls can run here."
        }
        let need = VoiceRequirements.minimumCardMB / 1_000
        let base = "No NVIDIA GPU with \(need) GB: voice calls cannot run on this machine."
        guard let name else { return base + " nvidia-smi found no NVIDIA GPU." }
        guard let total else { return base + " The memory size of \(Self.card(name)) could not be read." }
        return base + " The card here, \(Self.card(name)), has \(Self.gigabytes(mebibytes: total)) GB."
    }

    private func mark(_ state: SetupState) -> String {
        switch state {
        case .ok: unicode ? "✓" : "+"
        case .blocked, .unavailable: unicode ? "✗" : "x"
        case .todo: unicode ? "○" : "o"
        case .working: unicode ? "…" : "~"
        }
    }

    private func rows(for check: SetupCheck) -> [String] {
        var lines = ["  \(mark(check.state)) \(headline(check))"]
        lines += notes(for: check).map { "      \($0)" }
        if let fix = check.fix, fix.kind == .command, let command = fix.command {
            if let reason = fix.reason { lines.append("      \(reason)") }
            lines.append("      Run: \(command)")
        }
        return lines
    }

    private func headline(_ check: SetupCheck) -> String {
        let facts = check.facts
        if facts["mode"] == "external", check.state == .ok, check.id != "voice.engine" {
            return "\(Self.label(check.id)): not needed, a voice engine you run yourself is answering"
        }
        switch check.id {
        case "voice.gpu": return gpuHeadline(check)
        case "voice.vram": return vramHeadline(check)
        case "voice.docker": return dockerHeadline(check)
        case "voice.cdi": return cdiHeadline(check)
        case "voice.model": return modelHeadline(check)
        case "voice.image": return imageHeadline(check)
        case "voice.engine": return engineHeadline(check)
        case "voice.gateway": return "voice-bridge \(facts["version"] ?? "")"
        default: return "\(check.id): \(check.state.rawValue)"
        }
    }

    private static func label(_ id: String) -> String {
        switch id {
        case "voice.docker": "Docker"
        case "voice.cdi": "GPU for containers"
        case "voice.model": "Voice model"
        case "voice.image": "Voice engine image"
        default: id
        }
    }

    private func gpuHeadline(_ check: SetupCheck) -> String {
        guard check.state == .ok, let name = check.facts["name"] else { return "GPU: none found (nvidia-smi did not answer)" }
        return "GPU: \(name)"
    }

    private func vramHeadline(_ check: SetupCheck) -> String {
        let need = VoiceRequirements.minimumCardMB / 1_000
        guard let total = check.facts["totalMB"].flatMap(Int.init) else { return "GPU memory: could not be read" }
        let size = Self.gigabytes(mebibytes: total)
        if check.state == .ok { return "GPU memory: \(size) GB (the voice model needs a card with \(need) GB)" }
        return "GPU memory: \(size) GB, too small (the voice model needs a card with \(need) GB)"
    }

    private func dockerHeadline(_ check: SetupCheck) -> String {
        if check.state == .ok { return "Docker: works for this user" }
        switch check.facts["problem"] {
        case "denied": return "Docker: installed, but this user is not allowed to use it"
        case "stopped": return "Docker: installed, but not running"
        default: return "Docker: not installed"
        }
    }

    private func cdiHeadline(_ check: SetupCheck) -> String {
        if check.state == .ok { return "GPU for containers: set up" }
        if check.facts["toolkit"] == "missing" { return "GPU for containers: the NVIDIA Container Toolkit is not installed" }
        return "GPU for containers: not set up yet"
    }

    private func modelHeadline(_ check: SetupCheck) -> String {
        let size = check.facts["needBytes"].flatMap(Int64.init).map { "\(Self.gigabytes(bytes: $0)) GB" } ?? "44 GB"
        switch check.state {
        case .ok: return "Voice model: downloaded (\(size))"
        case .working: return "Voice model: downloading\(Self.progress(check.facts))"
        default:
            let have = check.facts["bytes"].flatMap(Int64.init) ?? 0
            return "Voice model: \(have > 0 ? "partly downloaded" : "not downloaded yet") (\(size)\(Self.time(check.fix))). Tailscode will do this for you."
        }
    }

    private func imageHeadline(_ check: SetupCheck) -> String {
        let size = check.facts["needBytes"].flatMap(Int64.init).map { "\(Self.gigabytes(bytes: $0)) GB" } ?? "23 GB"
        switch check.state {
        case .ok: return "Voice engine image: downloaded (\(size))"
        case .working: return "Voice engine image: downloading\(Self.progress(check.facts))"
        default:
            if check.facts["after"] == "voice.docker" { return "Voice engine image: waits for Docker" }
            return "Voice engine image: not downloaded yet (\(size)\(Self.time(check.fix))). Tailscode will do this for you."
        }
    }

    private func engineHeadline(_ check: SetupCheck) -> String {
        let facts = check.facts
        switch facts["state"] {
        case "running": return facts["mode"] == "external" ? "Voice engine: running, started by you" : "Voice engine: running"
        case "stopped": return "Voice engine: stopped, a call starts it when needed"
        case "loading": return "Voice engine: loading\(Self.progress(facts))"
        case "busy":
            let who = (facts["holders"] ?? "").split(separator: ",").joined(separator: ", ")
            let free = Self.gigabytes(mebibytes: facts["freeMB"].flatMap(Int.init) ?? 0)
            let need = (facts["needMB"].flatMap(Int.init) ?? VoiceRequirements.freeVRAMMB) / 1_000
            return "Voice engine: the GPU is held by \(who.isEmpty ? "another job" : who) (\(free) GB free, the voice model needs \(need) GB)"
        case "down" where facts["failure"] == EngineFailure.gpuMemory:
            let free = Self.gigabytes(mebibytes: facts["freeMB"].flatMap(Int.init) ?? 0)
            let need = Self.gigabytes(mebibytes: facts["needMB"].flatMap(Int.init) ?? 0)
            return "Voice engine: did not start, the GPU had \(free) GB free and the engine wanted \(need) GB for one of its two models"
        case "down": return "Voice engine: not running (\(facts["reason"] ?? "no reason given"))"
        default: return "Voice engine: waits for the steps above"
        }
    }

    private func notes(for check: SetupCheck) -> [String] {
        var found: [String] = []
        if check.id == "voice.engine", check.facts["state"] == "busy" {
            found.append("voice-bridge never stops another program's job: stop it, and a call starts the engine.")
        }
        if check.id == "voice.engine", check.facts["state"] == "down", let tail = check.facts["tail"] {
            found.append("The last lines of its log:")
            found += tail.split(whereSeparator: \.isNewline).suffix(3).map { "  \($0.prefix(160))" }
        }
        if let failure = check.facts["lastFailure"] {
            found.append("The last attempt failed (\(Self.failure(failure))). Tailscode will try again.")
        }
        return found
    }

    private static func failure(_ id: String) -> String {
        switch id {
        case "noDisk": "the disk is full"
        case "network": "the network failed"
        case "denied": "NVIDIA refused the sign-in, so an NGC API key is needed"
        case "interrupted": "it was interrupted"
        default: "something else went wrong"
        }
    }

    private static func time(_ fix: SetupFix?) -> String {
        guard let minutes = fix?.minutes else { return "" }
        return ", about \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    private static func progress(_ facts: [String: String]) -> String {
        guard let fraction = facts["progress"].flatMap(Double.init) else { return "" }
        return " (\(Int((fraction * 100).rounded()))%)"
    }

    private func closing(_ report: SetupReport) -> String {
        if !report.available { return "Nothing else was checked, because voice calls cannot run on this machine." }
        if report.ready { return "Everything is in place. Open Tailscode and start a call." }
        if !commands(report).isEmpty {
            return "Run the commands above that need administrator rights, then open Tailscode, pick this server and tap Set up voice."
        }
        if report.checks.contains(where: { $0.fix?.kind == .job || $0.state == .working }) {
            return "Open Tailscode, pick this server and tap Set up voice: it does the rest."
        }
        if check(report, "voice.engine")?.facts["state"] == "busy" {
            return "Everything is installed. Once the GPU is free again, a call starts the voice engine."
        }
        return "The lines above say what is left."
    }
}
