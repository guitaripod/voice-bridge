import Foundation
import SetupKit
import Testing
@testable import VoiceGatewayCore

@Suite(.serialized)
struct SetupRoutesTests {
    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try SetupCodec.decode(type, from: data)
    }

    func slowPull(_ jobs: JobHarness) async -> MachineGatewayHarness {
        jobs.installDocker(pull: "echo 'aaaaaaaaaaaa: Pulling fs layer'\nwhile [ ! -e '\(jobs.bin.url.path)/go' ]; do sleep 0.05; done\ntouch '\(jobs.bin.url.path)/image-present'")
        return await MachineGatewayHarness.start(
            FakeMachine(imageBytes: nil), runner: jobs.runner, root: jobs.root)
    }

    @Test func getSetupAnswersAListOfReportsForVoice() async throws {
        var machine = FakeMachine()
        machine.model = .partial(2_000_000_000)
        let harness = await MachineGatewayHarness.start(machine)
        defer { Task { await harness.stop() } }
        let (status, body) = try await harness.request("GET", "/setup")
        #expect(status == 200)
        let reports = try decode([SetupReport].self, body)
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.capability == "voice")
        #expect(report.available)
        #expect(!report.ready)
        #expect(report.firstOpen?.id == "voice.model")
        #expect(report.firstOpen?.fix?.id == "voice.downloadModel")
        #expect(report.checks.map(\.id).last == "voice.gateway")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasPrefix(#"[{"available":true,"capability":"voice","checks":[{"#))
    }

    @Test func theSetupRoutesAreBehindTheSamePassword() async throws {
        let harness = await MachineGatewayHarness.start(password: "s3cret")
        defer { Task { await harness.stop() } }
        for (method, path) in [("GET", "/setup"), ("POST", "/setup/fix"), ("GET", "/setup/jobs/x"), ("DELETE", "/setup/jobs/x")] {
            #expect(try await harness.request(method, path, body: method == "POST" ? #"{"fix":"voice.pullImage"}"# : nil).0 == 401)
            #expect(try await harness.request(method, path, token: "wrong").0 == 401)
        }
        #expect(try await harness.request("GET", "/setup", token: "s3cret").0 == 200)
        #expect(try await harness.request("GET", "/setup/jobs/x", token: "s3cret").0 == 404)
    }

    @Test func aGatewayWithoutMachineServicesHasNoSetupRoutes() async throws {
        let harness = await GatewayHarness.start()
        defer { Task { await harness.stop() } }
        #expect(try await harness.get("/setup").0 == 404)
    }

    @Test func badAndUnknownFixesAreRefusedWithClearStatuses() async throws {
        let harness = await MachineGatewayHarness.start()
        defer { Task { await harness.stop() } }
        #expect(try await harness.request("POST", "/setup/fix", body: "nonsense").0 == 400)
        #expect(try await harness.request("POST", "/setup/fix", body: "{}").0 == 400)
        #expect(try await harness.request("POST", "/setup/fix", body: #"{"fix":"voice.installDocker"}"#).0 == 404)
        let (status, body) = try await harness.request("POST", "/setup/fix", body: #"{"fix":"voice.nope"}"#)
        #expect(status == 404)
        #expect(String(decoding: body, as: UTF8.self).contains("voice.nope"))
        #expect(try await harness.request("GET", "/setup/jobs/missing").0 == 404)
        #expect(try await harness.request("DELETE", "/setup/jobs/missing").0 == 404)
    }

    @Test func aFixStartsAJobThatCanBeFollowedAndShowsOnTheReport() async throws {
        let jobs = JobHarness(model: .complete)
        let harness = await slowPull(jobs)
        defer { Task { await harness.stop() } }
        let (status, body) = try await harness.request("POST", "/setup/fix", body: #"{"fix":"voice.pullImage"}"#)
        #expect(status == 200)
        let job = try decode(SetupJob.self, body)
        #expect(job.fix == "voice.pullImage")
        #expect(job.state == .running)

        let followed = try decode(SetupJob.self, try await harness.request("GET", "/setup/jobs/\(job.id)").1)
        #expect(followed.id == job.id)
        let report = try decode([SetupReport].self, try await harness.request("GET", "/setup").1)[0]
        #expect(report.job?.id == job.id)
        #expect(report.checks.first { $0.id == "voice.image" }?.state == .working)

        jobs.release("go")
        #expect(await eventually {
            guard let data = try? await harness.request("GET", "/setup/jobs/\(job.id)").1 else { return false }
            return (try? SetupCodec.decode(SetupJob.self, from: data))?.state == .succeeded
        })
    }

    @Test func startingTheSameFixTwiceAnswersConflictWithTheRunningJob() async throws {
        let jobs = JobHarness(model: .complete)
        let harness = await slowPull(jobs)
        defer { Task { await harness.stop() } }
        let first = try decode(SetupJob.self, try await harness.request("POST", "/setup/fix", body: #"{"fix":"voice.pullImage"}"#).1)
        let (status, body) = try await harness.request("POST", "/setup/fix", body: #"{"fix":"voice.pullImage"}"#)
        #expect(status == 409)
        #expect(try decode(SetupJob.self, body).id == first.id)
        jobs.release("go")
    }

    @Test func deleteCancelsTheJobAndAnswersItSettled() async throws {
        let jobs = JobHarness(model: .complete)
        let harness = await slowPull(jobs)
        defer { Task { await harness.stop() } }
        let job = try decode(SetupJob.self, try await harness.request("POST", "/setup/fix", body: #"{"fix":"voice.pullImage"}"#).1)
        #expect(await eventually { (try? await harness.request("GET", "/setup/jobs/\(job.id)"))?.0 == 200 })
        try await Task.sleep(for: .milliseconds(300))
        let (status, body) = try await harness.request("DELETE", "/setup/jobs/\(job.id)")
        #expect(status == 200)
        #expect(try decode(SetupJob.self, body).state == .cancelled)
        let again = try await harness.request("DELETE", "/setup/jobs/\(job.id)")
        #expect(again.0 == 200)
        #expect(try decode(SetupJob.self, again.1).state == .cancelled)
        let report = try decode([SetupReport].self, try await harness.request("GET", "/setup").1)[0]
        #expect(report.job == nil)
    }

    @Test func aMachineThatCannotRunVoiceRefusesTheFix() async throws {
        var machine = FakeMachine()
        machine.totalMB = 49_140
        let harness = await MachineGatewayHarness.start(machine)
        defer { Task { await harness.stop() } }
        #expect(try await harness.request("POST", "/setup/fix", body: #"{"fix":"voice.downloadModel"}"#).0 == 422)
        #expect(harness.host.calls.allSatisfy { $0.executable != "ngc" })
    }

    @Test func theJobWireShapeIsStable() throws {
        let job = SetupJob(id: "job-1", fix: "voice.downloadModel", state: .failed, step: "download", fraction: 0.5, bytesDone: 10, bytesTotal: 20, failure: "noDisk", facts: ["needMB": "1", "freeMB": "0"], startedAt: 7)
        #expect(
            String(decoding: try SetupCodec.encode(job), as: UTF8.self)
                == #"{"bytesDone":10,"bytesTotal":20,"facts":{"freeMB":"0","needMB":"1"},"failure":"noDisk","fix":"voice.downloadModel","fraction":0.5,"id":"job-1","startedAt":7,"state":"failed","step":"download"}"#)
    }
}
