import AchtungDomain
import Foundation

// Converts GET /api/alertmanagers/{instance}/alerts to AchtungDomain's
// `AlertmanagerAlerts`, like HomeMapping.swift does for the tiles.

extension Components.Schemas.AlertmanagerAlertList {
    /// The spec promises: reachable with the time of its read; unreachable with an error,
    /// keeping its last read if there was one, and no alerts if there never was.
    func domain() throws -> AlertmanagerAlerts {
        let status: AlertmanagerAlerts.Status
        switch (reachable, error, checkedAt) {
        case (true, _, let checkedAt?):
            status = .reachable(checkedAt: checkedAt)
        case (false, let error?, let lastRead):
            status = .unreachable(error: error, lastRead: lastRead)
        case (true, _, nil):
            throw ServerError.invalidResponse(
                "Alertmanager \(instance) is reachable but was never read")
        case (false, nil, _):
            throw ServerError.invalidResponse(
                "Alertmanager \(instance) is unreachable without an error")
        }
        if checkedAt == nil, !alerts.isEmpty {
            throw ServerError.invalidResponse(
                "Alertmanager \(instance) was never read but lists alerts")
        }
        return AlertmanagerAlerts(
            instance: instance, status: status, alerts: try alerts.map { try $0.domain() })
    }
}

extension Components.Schemas.AlertmanagerAlert {
    func domain() throws -> AlertmanagerAlert {
        AlertmanagerAlert(
            fingerprint: fingerprint, title: title, severity: severity.domain, summary: summary,
            startsAt: startsAt, labels: labels.additionalProperties,
            annotations: annotations.additionalProperties, state: try alertState(),
            occurrenceID: occurrenceId)
    }

    /// Only a silenced alert has a silence to end; it may be one Achtung doesn't know yet.
    private func alertState() throws -> AlertmanagerAlert.State {
        switch (state, silencedUntil) {
        case (.active, nil): return .active
        case (.inhibited, nil): return .inhibited
        case (.silenced, let until): return .silenced(until: until)
        case (.active, .some), (.inhibited, .some):
            throw ServerError.invalidResponse(
                "Alert \(fingerprint) is \(state.rawValue) with silencedUntil set")
        }
    }
}

extension Components.Schemas.AlertmanagerAlert.SeverityPayload {
    var domain: Severity {
        switch self {
        case .critical: .critical
        case .warning: .warning
        case .info: .info
        case .unknown: .unknown
        }
    }
}
