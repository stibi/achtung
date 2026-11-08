import AchtungDomain
import Foundation

// Maps the generated OpenAPI types to AchtungDomain. This is the boundary: anything the
// domain can't represent is an invalid response, not something to patch over later.

extension Components.Schemas.Channel {
    var domain: Channel {
        Channel(
            id: ChannelID(instance: instance, slug: slug), firing: firing,
            lastEventAt: lastEventAt)
    }
}

extension Components.Schemas.Occurrence {
    func domain() throws -> Occurrence {
        Occurrence(
            id: id,
            channel: ChannelID(instance: instance, slug: channel),
            source: source,
            alert: IncomingAlert(
                sourceKey: sourceKey,
                severity: severity.domain,
                title: title,
                summary: summary,
                labels: labels.additionalProperties,
                annotations: annotations.additionalProperties,
                startsAt: startsAt,
                links: try links.map { try $0.domain() },
                state: try state()),
            firstReceivedAt: firstReceivedAt,
            lastReceivedAt: lastReceivedAt,
            lastEventAt: lastEventAt,
            notificationCount: notificationCount)
    }

    /// The spec promises `endsAt` is set exactly when the status is resolved.
    private func state() throws -> AlertState {
        switch (status, endsAt) {
        case (.firing, nil):
            return .firing
        case (.resolved, .some(let endsAt)):
            return .resolved(endsAt: endsAt)
        case (.firing, .some), (.resolved, nil):
            throw ServerError.invalidResponse(
                "Occurrence \(id) is \(status.rawValue) with endsAt \(String(describing: endsAt))")
        }
    }
}

extension Components.Schemas.Occurrence.SeverityPayload {
    var domain: Severity {
        switch self {
        case .critical: .critical
        case .warning: .warning
        case .info: .info
        case .unknown: .unknown
        }
    }
}

extension Components.Schemas.Occurrence.LinksPayloadPayload {
    func domain() throws -> AlertLink {
        guard let url = URL(string: url) else {
            throw ServerError.invalidResponse("Link is not a URL: \(url)")
        }
        return AlertLink(kind: kind.domain, url: url)
    }
}

extension Components.Schemas.Occurrence.LinksPayloadPayload.KindPayload {
    var domain: AlertLink.Kind {
        switch self {
        case .source: .source
        case .runbook: .runbook
        case .dashboard: .dashboard
        }
    }
}

extension Components.Schemas.Event {
    var domain: OccurrenceEvent {
        OccurrenceEvent(id: id, kind: kind.domain, recordedAt: recordedAt)
    }
}

extension Components.Schemas.Event.KindPayload {
    var domain: OccurrenceEvent.Kind {
        switch self {
        case .fired: .fired
        case .resolved: .resolved
        case .reopened: .reopened
        }
    }
}

extension Components.Schemas.OccurrenceDetail {
    func domain() throws -> OccurrenceDetail {
        OccurrenceDetail(
            occurrence: try occurrence.domain(),
            events: events.map(\.domain),
            otherOccurrences: try otherOccurrences.map { try $0.domain() })
    }
}

extension OccurrencePage {
    /// Both list routes, one channel and every channel, return this shape.
    init(_ page: Components.Schemas.OccurrencePage) throws {
        self.init(
            occurrences: try page.occurrences.map { try $0.domain() }, nextCursor: page.nextCursor)
    }
}
