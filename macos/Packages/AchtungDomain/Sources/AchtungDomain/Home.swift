import Foundation

/// The Home view: each Alertmanager as its own Alertmanager sees it, the silences active
/// on them, and the alerts that fired most and the ones firing longest, in Achtung.
public struct Home: Sendable, Hashable {
    /// Every configured Alertmanager, by instance name.
    public let alertmanagers: [AlertmanagerOverview]
    /// Active now, the soonest to end first.
    public let silences: [Silence]
    /// Most events in the last 24 hours first.
    public let noisiest: [NoisyAlert]
    /// The earliest start first.
    public let longestFiring: [Occurrence]

    public init(
        alertmanagers: [AlertmanagerOverview], silences: [Silence], noisiest: [NoisyAlert],
        longestFiring: [Occurrence]
    ) {
        self.alertmanagers = alertmanagers
        self.silences = silences
        self.noisiest = noisiest
        self.longestFiring = longestFiring
    }
}

/// One Alertmanager: whether Achtung can read it now, and what it last read there.
public struct AlertmanagerOverview: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        /// The latest read succeeded.
        case reachable(Read)
        /// The latest read failed, for this reason. It keeps its last successful read, nil
        /// if there never was one.
        case unreachable(error: String, lastRead: Read?)
    }

    /// A successful read of its alerts.
    public struct Read: Sendable, Hashable {
        public let checkedAt: Date
        /// Notifying alerts, not silenced or inhibited, without Watchdog and InfoInhibitor.
        public let open: OpenAlertCounts
        public let silenced: Int
        /// Inhibited and not silenced.
        public let inhibited: Int
        /// Whether the Watchdog alert fires, i.e. the alerting pipeline works.
        public let watchdogFires: Bool
        public let delivery: Delivery

        public init(
            checkedAt: Date, open: OpenAlertCounts, silenced: Int, inhibited: Int,
            watchdogFires: Bool, delivery: Delivery
        ) {
            self.checkedAt = checkedAt
            self.open = open
            self.silenced = silenced
            self.inhibited = inhibited
            self.watchdogFires = watchdogFires
            self.delivery = delivery
        }

        /// "4 silenced · 1 inhibited", leaving out zeros; nil when both are.
        public var quieted: String? {
            Self.joined([(silenced, "silenced"), (inhibited, "inhibited")])
        }

        static func joined(_ parts: [(Int, String)]) -> String? {
            let text = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            return text.isEmpty ? nil : text.joined(separator: " · ")
        }
    }

    public let instance: String
    public let status: Status

    public var id: String { instance }

    public init(instance: String, status: Status) {
        self.instance = instance
        self.status = status
    }

    /// The latest successful read, nil if it was never read.
    public var lastRead: Read? {
        switch status {
        case .reachable(let read): read
        case .unreachable(_, let read): read
        }
    }

    public var isReachable: Bool {
        if case .reachable = status { true } else { false }
    }
}

/// Notifying alerts by severity.
public struct OpenAlertCounts: Sendable, Hashable {
    /// What the total looks like: calm at zero, else the worst severity present.
    public enum Emphasis: Sendable, Hashable {
        case allQuiet
        case critical
        case warning
        /// Only info or unknown severities.
        case neutral
    }

    public let total: Int
    public let critical: Int
    public let warning: Int
    public let info: Int
    /// No severity label, or one Achtung doesn't know.
    public let other: Int

    public init(total: Int, critical: Int, warning: Int, info: Int, other: Int) {
        self.total = total
        self.critical = critical
        self.warning = warning
        self.info = info
        self.other = other
    }

    public var emphasis: Emphasis {
        if total == 0 {
            .allQuiet
        } else if critical > 0 {
            .critical
        } else if warning > 0 {
            .warning
        } else {
            .neutral
        }
    }

    /// Each severity with its count, most severe first, leaving out zeros: the stacked bar.
    public var bySeverity: [(severity: Severity, count: Int)] {
        [(.critical, critical), (.warning, warning), (.info, info), (.unknown, other)]
            .filter { $0.1 > 0 }
    }

    /// "3 critical · 8 warning · 2 info · 2 other", leaving out zeros; nil at zero.
    public var breakdown: String? {
        AlertmanagerOverview.Read.joined([
            (critical, "critical"), (warning, "warning"), (info, "info"), (other, "other"),
        ])
    }
}

/// How the Alertmanager's alerts and Achtung's compare: where delivery broke.
public struct Delivery: Sendable, Hashable {
    /// Notifying in Alertmanager for over 10 minutes on a receiver that feeds Achtung,
    /// but not firing in Achtung. Oldest first.
    public let missingInAchtung: [MissingAlert]
    /// Firing in Achtung but gone from Alertmanager: a resolve that never arrived.
    public let staleInAchtung: [Occurrence]

    public init(missingInAchtung: [MissingAlert], staleInAchtung: [Occurrence]) {
        self.missingInAchtung = missingInAchtung
        self.staleInAchtung = staleInAchtung
    }

    /// "2 missing · 1 stale", leaving out zeros; nil when delivery is healthy.
    public var summary: String? {
        AlertmanagerOverview.Read.joined([
            (missingInAchtung.count, "missing"), (staleInAchtung.count, "stale"),
        ])
    }
}

/// An alert Alertmanager sends that never reached Achtung.
public struct MissingAlert: Sendable, Hashable, Identifiable {
    /// Alertmanager's fingerprint, which would be an occurrence's source key.
    public let fingerprint: String
    public let title: String
    public let severity: Severity
    public let startsAt: Date

    public var id: String { fingerprint }

    public init(fingerprint: String, title: String, severity: Severity, startsAt: Date) {
        self.fingerprint = fingerprint
        self.title = title
        self.severity = severity
        self.startsAt = startsAt
    }
}

/// An alert with its events in the last 24 hours, as its newest occurrence.
public struct NoisyAlert: Sendable, Hashable, Identifiable {
    public let occurrence: Occurrence
    /// Fired, reopened and resent events in the last 24 hours.
    public let events: Int

    public var id: Int { occurrence.id }

    public init(occurrence: Occurrence, events: Int) {
        self.occurrence = occurrence
        self.events = events
    }
}

/// "2h 10m", "3d 4h", "45m": the two largest units of a span, for "ends in" and "firing
/// for". Under a minute is "under a minute"; a negative span counts as zero.
public func shortDuration(_ interval: TimeInterval) -> String {
    let minutes = max(Int(interval / 60), 0)
    let (days, hours) = (minutes / 1440, minutes % 1440 / 60)
    switch minutes {
    case 0: return "under a minute"
    case ..<60: return "\(minutes)m"
    case ..<1440: return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m"
    default: return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }
}
