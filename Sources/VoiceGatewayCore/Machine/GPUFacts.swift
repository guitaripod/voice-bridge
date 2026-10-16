import Foundation

struct GPUHolder: Sendable, Equatable {
    var pid: Int
    var name: String
    var usedMB: Int
}

struct GPUFacts: Sendable, Equatable {
    var name: String
    var totalMB: Int?
    var usedMB: Int?
    var holders: [GPUHolder] = []

    var freeMB: Int? {
        guard let totalMB, let usedMB else { return nil }
        return max(0, totalMB - usedMB)
    }

    /// The jobs worth naming: everything holding a gigabyte or more, largest first, each program once.
    /// When nothing is that big, the three largest.
    var holderNames: [String] {
        var seen: [String: Int] = [:]
        for holder in holders { seen[holder.name, default: 0] += holder.usedMB }
        let ranked = seen.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let heavy = ranked.filter { $0.value >= 1_000 }
        return (heavy.isEmpty ? Array(ranked.prefix(3)) : Array(heavy.prefix(5))).map(\.key)
    }
}

enum NvidiaSMI {
    static let gpuQuery = ["--query-gpu=name,memory.total,memory.used", "--format=csv,noheader,nounits"]
    static let holderQuery = ["--query-compute-apps=pid,process_name,used_memory", "--format=csv,noheader,nounits"]

    /// The first GPU, which is the one CDI device `0` hands to the container. The name may contain
    /// commas, so the two numbers are taken from the right.
    static func parseGPU(_ output: String) -> GPUFacts? {
        guard let line = output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        let parts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return GPUFacts(name: line) }
        let name = parts.dropLast(2).joined(separator: ", ")
        return GPUFacts(name: name, totalMB: Int(parts[parts.count - 2]), usedMB: Int(parts[parts.count - 1]))
    }

    /// `pid, process_name, used_memory`: the pid is the first field and the memory the last, the name is
    /// whatever lies between (a full command line may contain commas). Only the program's own name is kept.
    static func parseHolders(_ output: String) -> [GPUHolder] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard let first = line.firstIndex(of: ","), let last = line.lastIndex(of: ","), first < last,
                let pid = Int(line[..<first].trimmingCharacters(in: .whitespaces)),
                let used = Int(line[line.index(after: last)...].trimmingCharacters(in: .whitespaces))
            else { return nil }
            let command = line[line.index(after: first)..<last].trimmingCharacters(in: .whitespaces)
            return GPUHolder(pid: pid, name: programName(command), usedMB: used)
        }
    }

    static func programName(_ command: String) -> String {
        let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        let base = first.split(separator: "/").last.map(String.init) ?? first
        return base.isEmpty ? "unknown" : base
    }
}
