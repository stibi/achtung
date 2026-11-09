import Foundation

/// The alerts behind an Alertmanager's tile on Home, from the same read as its counts:
/// the active ones are its open alerts, the others its silenced and inhibited.
public struct AlertmanagerAlerts: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// The latest read succeeded, at this time.
        case reachable(checkedAt: Date)
        /// The latest read failed, for this reason. The alerts are from the last read
        /// that succeeded, at `lastRead`; nil and no alerts if none ever did.
        case unreachable(error: String, lastRead: Date?)
    }

    public let instance: String
    public let status: Status
    /// By severity, then the newest start first.
    public let alerts: [AlertmanagerAlert]

    public init(instance: String, status: Status, alerts: [AlertmanagerAlert]) {
        self.instance = instance
        self.status = status
        self.alerts = alerts
    }

    /// The active alerts by severity, most severe first, leaving out severities with none.
    public var activeBySeverity: [(severity: Severity, alerts: [AlertmanagerAlert])] {
        let active = alerts.filter { $0.state == .active }
        return [Severity.critical, .warning, .info, .unknown].compactMap { severity in
            let matching = active.filter { $0.severity == severity }
            return matching.isEmpty ? nil : (severity, matching)
        }
    }

    public var silenced: [AlertmanagerAlert] {
        alerts.filter { if case .silenced = $0.state { true } else { false } }
    }

    public var inhibited: [AlertmanagerAlert] {
        alerts.filter { $0.state == .inhibited }
    }

    /// When its alerts were last read, nil if never.
    public var checkedAt: Date? {
        switch status {
        case .reachable(let checkedAt): checkedAt
        case .unreachable(_, let lastRead): lastRead
        }
    }
}

/// One alert as its Alertmanager has it.
public struct AlertmanagerAlert: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// Notifying, or not routed yet.
        case active
        /// A silence mutes it, until this time if Achtung knows that silence.
        case silenced(until: Date?)
        /// Only inhibited.
        case inhibited
    }

    /// Labels worth a glance in a list, in this order; the rest stay in the details.
    static let keyLabelNames = [
        "namespace", "pod", "job", "service", "deployment", "container", "instance", "cluster",
    ]

    /// Alertmanager's fingerprint, an occurrence's source key.
    public let fingerprint: String
    public let title: String
    public let severity: Severity
    public let summary: String?
    public let startsAt: Date
    public let labels: [String: String]
    public let annotations: [String: String]
    public let state: State
    /// The Achtung occurrence of this firing; nil when Achtung has none.
    public let occurrenceID: Int?

    public var id: String { fingerprint }

    /// Its alertname label, which an ignored alert name matches; nil without one.
    public var alertname: String? { labels["alertname"] }

    public init(
        fingerprint: String, title: String, severity: Severity, summary: String?,
        startsAt: Date, labels: [String: String], annotations: [String: String],
        state: State, occurrenceID: Int?
    ) {
        self.fingerprint = fingerprint
        self.title = title
        self.severity = severity
        self.summary = summary
        self.startsAt = startsAt
        self.labels = labels
        self.annotations = annotations
        self.state = state
        self.occurrenceID = occurrenceID
    }

    /// Up to three labels that tell where it fires, e.g. namespace, pod or job.
    public var keyLabels: [(name: String, value: String)] {
        Self.keyLabelNames.compactMap { name in labels[name].map { (name, $0) } }
            .prefix(3).map { $0 }
    }

    /// Every label but alertname and severity, which the row shows already, by name.
    public var otherLabels: [(name: String, value: String)] {
        labels.filter { !["alertname", "severity"].contains($0.key) }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
