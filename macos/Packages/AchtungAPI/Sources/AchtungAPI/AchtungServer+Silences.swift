import AchtungDomain
import Foundation

// Ending an alert's silence (ADR 0015) and silencing several of an Alertmanager's alerts at
// once (ADR 0016). Silencing one occurrence is `AchtungServer.silence(occurrenceID:for:)`.

extension AchtungServer {
    /// Ends the alert's own silences now and returns the occurrence. Its `silencedUntil` is
    /// still set when a broader silence mutes it too. `.silenceFailed` when only a broader
    /// silence mutes it (end it in Alertmanager), or Alertmanager couldn't be reached.
    public func unsilence(occurrenceID id: Int) async throws(ServerError) -> Occurrence {
        try await call {
            switch try await client.unsilenceOccurrence(path: .init(id: id)) {
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

    /// Silences each of these alerts of `instance`'s Alertmanager, by fingerprint, with its
    /// own exact silence for `duration` from now; one result per fingerprint, in that order.
    /// `.silenceFailed` when Alertmanager couldn't be reached or refused: some silences may
    /// be made, and trying again changes them rather than adding more.
    public func silenceAlerts(
        _ fingerprints: [String], of instance: String, for duration: SilenceDuration
    ) async throws(ServerError) -> [AlertSilenceResult] {
        try await call {
            let output = try await client.silenceAlertmanagerAlerts(
                path: .init(instance: instance),
                body: .json(.init(fingerprints: fingerprints, durationSeconds: duration.seconds)))
            switch output {
            case .ok(let response):
                return try response.body.json.alerts.map { try $0.domain() }
            case .badRequest(let response):
                throw ServerError.rejected(try response.body.json.error)
            case .notFound(let response):
                throw ServerError.notFound(try response.body.json.error)
            case .badGateway(let response):
                throw ServerError.silenceFailed(try response.body.json.error)
            case .undocumented(let status, _):
                throw ServerError.invalidResponse("HTTP \(status)")
            }
        }
    }
}

extension Components.Schemas.AlertsSilenced.AlertsPayloadPayload {
    /// Silenced with an end, or not with a reason: never both, never neither.
    func domain() throws -> AlertSilenceResult {
        switch (silencedUntil, error) {
        case (let until?, nil):
            return AlertSilenceResult(fingerprint: fingerprint, outcome: .silenced(until: until))
        case (nil, let error?):
            return AlertSilenceResult(fingerprint: fingerprint, outcome: .failed(error))
        default:
            throw ServerError.invalidResponse(
                "Silencing alert \(fingerprint) came back with "
                    + (error == nil ? "neither an end nor an error" : "both an end and an error"))
        }
    }
}
