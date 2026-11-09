import AchtungDomain
import Foundation

// Converts GET /api/home's generated types to AchtungDomain's `Home`, like Mapping.swift
// does for occurrences.

extension Components.Schemas.Home {
    func domain() throws -> Home {
        Home(
            alertmanagers: try alertmanagers.map { try $0.domain() },
            silences: silences.map(\.domain),
            noisiest: try noisiest.map {
                NoisyAlert(occurrence: try $0.occurrence.domain(), events: $0.events)
            },
            longestFiring: try longestFiring.map { try $0.domain() })
    }
}

extension Components.Schemas.AlertmanagerOverview {
    func domain() throws -> AlertmanagerOverview {
        let read = try lastRead()
        switch (reachable, read, error) {
        case (true, let read?, _):
            return AlertmanagerOverview(instance: instance, status: .reachable(read))
        case (false, _, let error?):
            return AlertmanagerOverview(
                instance: instance, status: .unreachable(error: error, lastRead: read))
        case (true, nil, _):
            throw ServerError.invalidResponse(
                "Alertmanager \(instance) is reachable but was never read")
        case (false, _, nil):
            throw ServerError.invalidResponse(
                "Alertmanager \(instance) is unreachable without an error")
        }
    }

    /// The spec promises the read's fields are null together, until the first successful
    /// read, and set together after it.
    private func lastRead() throws -> AlertmanagerOverview.Read? {
        switch (checkedAt, open, silenced, inhibited, watchdog, delivery) {
        case (
            let checkedAt?, let open?, let silenced?, let inhibited?, let watchdog?, let delivery?
        ):
            return AlertmanagerOverview.Read(
                checkedAt: checkedAt,
                open: OpenAlertCounts(
                    total: open.value1.total, critical: open.value1.critical,
                    warning: open.value1.warning, info: open.value1.info,
                    other: open.value1.other),
                silenced: silenced, inhibited: inhibited, watchdogFires: watchdog == .firing,
                delivery: Delivery(
                    missingInAchtung: delivery.value1.missingInAchtung.map(\.domain),
                    staleInAchtung: try delivery.value1.staleInAchtung.map { try $0.domain() }))
        case (nil, nil, nil, nil, nil, nil):
            return nil
        default:
            throw ServerError.invalidResponse(
                "Alertmanager \(instance) was read only in part (checkedAt, open, silenced, "
                    + "inhibited, watchdog and delivery are null together)")
        }
    }
}

extension Components.Schemas.MissingAlert {
    var domain: MissingAlert {
        let severity: Severity =
            switch self.severity {
            case .critical: .critical
            case .warning: .warning
            case .info: .info
            case .unknown: .unknown
            }
        return MissingAlert(
            fingerprint: fingerprint, title: title, severity: severity, startsAt: startsAt)
    }
}

extension Components.Schemas.Silence {
    var domain: Silence {
        Silence(
            instance: instance, silenceID: id, endsAt: endsAt,
            createdBy: createdBy, comment: comment,
            matchers: matchers.map {
                Silence.Matcher(
                    name: $0.name, value: $0.value, isRegex: $0.isRegex, isEqual: $0.isEqual)
            })
    }
}
