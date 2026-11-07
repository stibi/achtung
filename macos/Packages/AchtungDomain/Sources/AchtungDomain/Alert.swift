import Foundation

/// Mirrors `server/src/domain/alert.ts`. Keep the two in sync until the API client is
/// generated from `api/openapi.yaml`.
public enum Severity: String, Sendable, Hashable {
    case critical
    case warning
    case info
    case unknown

    /// Maps a source's free-form severity to Achtung's. Anything unrecognized is `.unknown`.
    /// Mirrors the server's `parseSeverity`; the app has no caller until the API client
    /// decodes severities from the server.
    public init(parsing value: String?) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = normalized.flatMap(Severity.init(rawValue:)) ?? .unknown
    }
}

public struct AlertLink: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case source
        case runbook
        case dashboard
    }

    public let kind: Kind
    public let url: URL

    public init(kind: Kind, url: URL) {
        self.kind = kind
        self.url = url
    }
}

/// A firing alert has no end yet; a resolved one always has one.
public enum AlertState: Sendable, Hashable {
    case firing
    case resolved(endsAt: Date)
}

/// An alert as reported by a source, already mapped to Achtung's model.
public struct IncomingAlert: Sendable, Hashable {
    /// Stable identity of the alert within its source, e.g. Alertmanager's fingerprint.
    public let sourceKey: String
    public let severity: Severity
    public let title: String
    public let summary: String?
    public let labels: [String: String]
    public let annotations: [String: String]
    /// Together with `sourceKey` identifies one occurrence; a re-fire after resolve is new.
    public let startsAt: Date
    public let links: [AlertLink]
    public let state: AlertState

    public init(
        sourceKey: String,
        severity: Severity,
        title: String,
        summary: String?,
        labels: [String: String],
        annotations: [String: String],
        startsAt: Date,
        links: [AlertLink],
        state: AlertState
    ) {
        self.sourceKey = sourceKey
        self.severity = severity
        self.title = title
        self.summary = summary
        self.labels = labels
        self.annotations = annotations
        self.startsAt = startsAt
        self.links = links
        self.state = state
    }

    public var isFiring: Bool {
        if case .firing = state { true } else { false }
    }
}
