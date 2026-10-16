import Foundation
import SetupKit

/// Jobs as JSON files, one per job, so a restart finds them.
struct JobStore: Sendable {
    static let keep = 20

    let directory: URL

    func save(_ job: SetupJob) {
        guard let data = try? SetupCodec.encode(job) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(job.id), options: .atomic)
    }

    func loadAll() -> [SetupJob] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            return try? SetupCodec.decode(SetupJob.self, from: data)
        }
    }

    func prune(_ jobs: [SetupJob]) -> [SetupJob] {
        let settled = jobs.filter { $0.state.isSettled }.sorted { $0.startedAt > $1.startedAt }
        let dropped = Set(settled.dropFirst(Self.keep).map(\.id))
        for id in dropped { try? FileManager.default.removeItem(at: file(id)) }
        return jobs.filter { !dropped.contains($0.id) }
    }

    private func file(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}
