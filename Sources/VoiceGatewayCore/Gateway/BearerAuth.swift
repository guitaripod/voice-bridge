import Hummingbird

/// `Authorization: Bearer <password>` on every route when a password is set. The comparison does
/// not stop at the first differing byte.
struct BearerAuth<Context: RequestContext>: RouterMiddleware {
    let password: String?

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let password else { return try await next(request, context) }
        guard let header = request.headers[.authorization], Self.matches(header: header, password: password) else {
            throw HTTPError(.unauthorized, message: "bearer token required")
        }
        return try await next(request, context)
    }

    static func matches(header: String, password: String) -> Bool {
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return false }
        return constantTimeEqual(Array(header.dropFirst(prefix.count).utf8), Array(password.utf8))
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }
}
