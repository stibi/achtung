import AchtungDomain
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

#if canImport(FoundationNetworking)
    import FoundationNetworking  // URLSession on Linux
#endif

/// The Achtung server's client API. Everything it returns is an AchtungDomain type; the
/// generated OpenAPI types stay inside this package.
public struct AchtungServer: Sendable {
    private let client: Client

    public init(baseURL: URL) {
        // An inbox must never show a cached answer: every request goes to the server.
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        self.init(
            baseURL: baseURL, transport: URLSessionTransport(configuration: .init(session: session))
        )
    }

    init(baseURL: URL, transport: any ClientTransport) {
        client = Client(
            serverURL: baseURL,
            // The server writes dates with milliseconds (JavaScript's toISOString).
            configuration: Configuration(dateTranscoder: .iso8601WithFractionalSeconds),
            transport: transport)
    }

    /// All channels, by name, with what is firing in each.
    public func channels() async throws(ServerError) -> [Channel] {
        try await call {
            switch try await client.listChannels() {
            case .ok(let response):
                return try response.body.json.channels.map(\.domain)
            case .undocumented(let status, _):
                throw ServerError.invalidResponse("HTTP \(status)")
            }
        }
    }

    /// One page of occurrences in `scope`, most recently changed first. Pass the page's
    /// `nextCursor` back to get the next one.
    public func occurrences(in scope: OccurrenceScope, after cursor: String? = nil)
        async throws(ServerError) -> OccurrencePage
    {
        try await call {
            switch scope {
            case .allChannels:
                switch try await client.listOccurrences(query: .init(cursor: cursor)) {
                case .ok(let response):
                    return try OccurrencePage(response.body.json)
                case .badRequest(let response):
                    throw ServerError.rejected(try response.body.json.error)
                case .undocumented(let status, _):
                    throw ServerError.invalidResponse("HTTP \(status)")
                }
            case .channel(let channel):
                let output = try await client.listInstanceChannelOccurrences(
                    path: .init(instance: channel.instance, slug: channel.slug),
                    query: .init(cursor: cursor))
                switch output {
                case .ok(let response):
                    return try OccurrencePage(response.body.json)
                case .badRequest(let response):
                    throw ServerError.rejected(try response.body.json.error)
                case .notFound(let response):
                    throw ServerError.notFound(try response.body.json.error)
                case .undocumented(let status, _):
                    throw ServerError.invalidResponse("HTTP \(status)")
                }
            }
        }
    }

    /// Every occurrence in `scope` that changed at or after `since`, following
    /// `nextCursor` until the pages reach older changes.
    public func occurrences(in scope: OccurrenceScope, changedSince since: Date)
        async throws(ServerError) -> [Occurrence]
    {
        var changed: [Occurrence] = []
        var cursor: String?
        repeat {
            let page = try await occurrences(in: scope, after: cursor)
            changed += page.occurrences.filter { $0.lastEventAt >= since }
            if page.occurrences.contains(where: { $0.lastEventAt < since }) {
                break
            }
            cursor = page.nextCursor
        } while cursor != nil
        return changed
    }

    /// One occurrence with its history and the alert's other occurrences.
    public func occurrence(id: Int) async throws(ServerError) -> OccurrenceDetail {
        try await call {
            switch try await client.getOccurrence(path: .init(id: id)) {
            case .ok(let response):
                return try response.body.json.domain()
            case .badRequest(let response):
                throw ServerError.rejected(try response.body.json.error)
            case .notFound(let response):
                throw ServerError.notFound(try response.body.json.error)
            case .undocumented(let status, _):
                throw ServerError.invalidResponse("HTTP \(status)")
            }
        }
    }

    /// Runs one request and turns whatever it throws into a `ServerError`. The generated
    /// client wraps transport and decoding failures in `ClientError`; a body in an
    /// unexpected content type throws from `body.json`.
    private func call<Output>(_ request: () async throws -> Output) async throws(ServerError)
        -> Output
    {
        do {
            return try await request()
        } catch let error as ServerError {
            throw error
        } catch let error as ClientError where error.underlyingError is DecodingError {
            throw .invalidResponse(String(describing: error.underlyingError))
        } catch let error as ClientError {
            throw .unreachable(error.underlyingError.localizedDescription)
        } catch {
            throw .invalidResponse(String(describing: error))
        }
    }
}

/// A page of occurrences and where the next one starts; `nextCursor` is nil on the last.
public struct OccurrencePage: Sendable {
    public let occurrences: [Occurrence]
    public let nextCursor: String?
}
