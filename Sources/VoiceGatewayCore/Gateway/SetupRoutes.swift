import Foundation
import Hummingbird
import NIOCore
import SetupKit

/// `GET /setup`, `POST /setup/fix`, `GET` and `DELETE /setup/jobs/{id}`, all through `SetupCodec` and
/// behind the same bearer password as `/health`.
enum SetupRoutes {
    static let jobPath = "\(SetupWire.jobsPath)/:id"

    static func add(to router: Router<BasicRequestContext>, services: MachineServices) {
        router.get(RouterPath(SetupWire.setupPath)) { _, _ -> Response in
            try response(await services.reports())
        }
        router.post(RouterPath(SetupWire.fixPath)) { request, _ -> Response in
            let body = try await request.body.collect(upTo: 4_096)
            guard let fix = try? SetupCodec.decode(SetupFixRequest.self, from: Data(buffer: body)) else {
                throw HTTPError(.badRequest, message: "the body must be {\"fix\": \"<id>\"}")
            }
            return try await start(fix.fix, services)
        }
        router.get(RouterPath(jobPath)) { _, context -> Response in
            guard let job = await services.jobs.job(context.parameters.get("id") ?? "") else {
                throw HTTPError(.notFound, message: "no such job")
            }
            return try response(job)
        }
        router.delete(RouterPath(jobPath)) { _, context -> Response in
            guard let job = await services.jobs.cancel(context.parameters.get("id") ?? "") else {
                throw HTTPError(.notFound, message: "no such job")
            }
            await services.facts.forget()
            return try response(job)
        }
    }

    private static func start(_ fix: String, _ services: MachineServices) async throws -> Response {
        do {
            let job = try await services.jobs.start(fix: fix)
            await services.facts.forget()
            return try response(job)
        } catch SetupJobError.unknownFix {
            throw HTTPError(.notFound, message: "unknown fix \(fix)")
        } catch SetupJobError.alreadyRunning(let running) {
            return try response(running, status: .conflict)
        } catch SetupJobError.unsupported {
            throw HTTPError(.unprocessableContent, message: "this machine cannot run the voice model")
        }
    }

    private static func response<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        Response(
            status: status, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: try SetupCodec.encode(value))))
    }
}
