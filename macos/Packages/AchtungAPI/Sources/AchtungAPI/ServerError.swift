/// Why a request to the server failed. Each case carries a message for the UI.
public enum ServerError: Error, Equatable, Sendable {
    /// No answer: the server is down, unreachable, or the connection broke.
    case unreachable(String)
    /// The server answered with something that doesn't match `api/openapi.yaml`.
    case invalidResponse(String)
    /// 404: the channel or occurrence doesn't exist (any more).
    case notFound(String)
    /// 400: the server rejected the request, e.g. a cursor it never issued.
    case rejected(String)
}
