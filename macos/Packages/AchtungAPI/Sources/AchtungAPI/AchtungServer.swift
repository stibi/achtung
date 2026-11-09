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

    /// Every occurrence that is firing now, in every channel, paging to the end. Unlike
    /// the feed, this includes alerts that started long ago and still fire, whose last
    /// event is old.
    public func firingOccurrences() async throws(ServerError) -> [Occurrence] {
        var firing: [Occurrence] = []
        var cursor: String?
        repeat {
            let page = try await call {
                switch try await client.listOccurrences(
                    query: .init(status: .firing, cursor: cursor))
                {
                case .ok(let response):
                    return try OccurrencePage(response.body.json)
                case .badRequest(let response):
                    throw ServerError.rejected(try response.body.json.error)
                case .undocumented(let status, _):
                    throw ServerError.invalidResponse("HTTP \(status)")
                }
            }
            firing += page.occurrences
            cursor = page.nextCursor
        } while cursor != nil
        return firing
    }

    /// Every occurrence on the pages of `scope` down to `since`: all that changed at or after
    /// it, following `nextCursor` until a page reaches older changes, plus the older ones on
    /// that last page. Those are returned too, because state the server derives without
    /// moving `lastEventAt`, like `silencedUntil` (ADR 0008), may have changed on them.
    public func occurrences(in scope: OccurrenceScope, changedSince since: Date)
        async throws(ServerError) -> [Occurrence]
    {
        var changed: [Occurrence] = []
        var cursor: String?
        repeat {
            let page = try await occurrences(in: scope, after: cursor)
            changed += page.occurrences
            if page.occurrences.contains(where: { $0.lastEventAt < since }) {
                break
            }
            cursor = page.nextCursor
        } while cursor != nil
        return changed
    }

    /// Silences the occurrence's alert on its instance's Alertmanager for `duration`,
    /// matching every label of the alert (ADR 0008), and returns the occurrence with its
    /// new `silencedUntil`. The silence mutes the alert for every receiver of that
    /// Alertmanager, not only Achtung.
    public func silence(occurrenceID id: Int, for duration: SilenceDuration)
        async throws(ServerError) -> Occurrence
    {
        try await call {
            let output = try await client.silenceOccurrence(
                path: .init(id: id), body: .json(.init(durationSeconds: duration.seconds)))
            switch output {
            case .ok(let response):
                return try response.body.json.domain()
            case .badRequest(let response):
                throw ServerError.rejected(try response.body.json.error)
            case .notFound(let response):
                throw ServerError.notFound(try response.body.json.error)
            case .conflict(let response):
                throw ServerError.silenceFailed(try response.body.json.error)
            case .badGateway(let response):
                throw ServerError.silenceFailed(try response.body.json.error)
            case .undocumented(let status, _):
                throw ServerError.invalidResponse("HTTP \(status)")
            }
        }
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

    /// The Home view: each Alertmanager's state as last read (the server reads them at
    /// most every 30 seconds), active silences, and the noisiest and longest firing alerts.
    public func home() async throws(ServerError) -> Home {
        try await call {
            switch try await client.getHome() {
            case .ok(let response):
                return try response.body.json.domain()
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
