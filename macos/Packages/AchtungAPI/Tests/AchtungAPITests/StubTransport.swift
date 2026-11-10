import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Answers requests from JSON fixtures instead of the network. A request without a route
/// fails like an unreachable server.
struct StubTransport: ClientTransport {
    struct Route {
        let status: Int
        let fixture: String
    }

    /// Keyed by request path including the query, e.g. `/api/channels`.
    let routes: [String: Route]
    /// Records the body of each request, for tests that check what the client sent.
    var log: RequestLog?

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String)
        async throws -> (HTTPResponse, HTTPBody?)
    {
        if let body, let log {
            let data = try await Data(collecting: body, upTo: 1 << 16)
            await log.append(String(bytes: data, encoding: .utf8) ?? "")
        }
        await log?.append(path: request.path ?? "")
        // A route without a query matches the path with any query, e.g. a search's.
        let path = request.path ?? ""
        let withoutQuery = String(path.prefix { $0 != "?" })
        guard let route = routes[path] ?? routes[withoutQuery] else {
            throw URLError(.cannotConnectToHost)
        }
        guard
            let url = Bundle.module.url(
                forResource: route.fixture, withExtension: "json", subdirectory: "Fixtures")
        else {
            throw URLError(.fileDoesNotExist)
        }
        let response = HTTPResponse(
            status: .init(code: route.status), headerFields: [.contentType: "application/json"])
        return (response, HTTPBody(try Data(contentsOf: url)))
    }
}

/// The request bodies and paths a `StubTransport` received, in order.
actor RequestLog {
    private(set) var bodies: [String] = []
    private(set) var paths: [String] = []

    func append(_ body: String) {
        bodies.append(body)
    }

    func append(path: String) {
        paths.append(path)
    }
}
