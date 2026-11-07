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

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String)
        async throws -> (HTTPResponse, HTTPBody?)
    {
        guard let route = routes[request.path ?? ""] else {
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
