import Foundation

/// Which occurrences a macOS notification announces (ADR 0013): a new firing or a resend
/// (ADR 0009) after the app's start, of a severity the user picked, not silenced, not read,
/// not of an ignored alert name (ADR 0011), and each event once.
public struct NotificationRules: Sendable, Equatable {
    public var severities: Set<Severity>
    /// The server's ignored alert names: an alert whose alertname is one never notifies.
    public var ignoredNames: Set<String>

    public init(severities: Set<Severity>, ignoredNames: Set<String>) {
        self.severities = severities
        self.ignoredNames = ignoredNames
    }
}

/// Per occurrence, the event a notification announced, so an event notifies once. In memory:
/// across launches the baseline (`AlertNotificationState`) keeps old events quiet.
public struct NotificationLedger: Sendable, Equatable {
    /// Occurrence id → the `lastEventAt` that was announced.
    public private(set) var notified: [Int: Date] = [:]

    public init() {}

    /// Whether this event of the occurrence was announced already.
    public func hasNotified(_ occurrence: Occurrence) -> Bool {
        notified[occurrence.id].map { $0 >= occurrence.lastEventAt } ?? false
    }

    public mutating func record(_ occurrences: [Occurrence]) {
        for occurrence in occurrences {
            notified[occurrence.id] = occurrence.lastEventAt
        }
    }

    /// The occurrences in `feed` to announce now, newest event first: what `rules` lets
    /// through, after the launch's `baseline`, unread, and not announced yet.
    public func notifying(
        in feed: [Occurrence], after baseline: Date, rules: NotificationRules,
        readState: ReadState, now: Date
    ) -> [Occurrence] {
        feed.filter { occurrence in
            let alert = occurrence.alert
            return alert.isFiring
                && [.fired, .reopened, .resent].contains(occurrence.lastEventKind)
                && occurrence.lastEventAt > baseline
                && rules.severities.contains(alert.severity)
                && !(alert.labels["alertname"].map(rules.ignoredNames.contains) ?? false)
                && !occurrence.isSilenced(at: now)
                && !readState.isRead(occurrence)
                && !hasNotified(occurrence)
        }
        .sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// Forgets events older than `date`: they can't come back, and the ledger stays small.
    public mutating func forget(before date: Date) {
        notified = notified.filter { $0.value >= date }
    }
}

/// How a refresh's notifying occurrences are announced.
public enum NotificationDelivery: Sendable, Equatable {
    /// One notification each.
    case each([Occurrence])
    /// More than `AlertNotificationPlan.summaryLimit` at once: one that sums them up.
    case summary([Occurrence])
}

/// What decides the notifications of one connection to a server: the launch's baseline and
/// the ledger. Feed it each refresh; it returns what to announce.
public struct AlertNotificationState: Sendable {
    /// Events up to it don't notify. Nil until the first refresh, which only sets it.
    public private(set) var baseline: Date?
    public private(set) var ledger = NotificationLedger()
    /// The severities of the last refresh: a newly picked one starts from now too.
    private var severities: Set<Severity>?

    public init() {}

    /// After a refresh: the occurrences to announce, recorded as announced. The first
    /// refresh, and one while notifications are off or paused (`isOn` false), only move the
    /// baseline to the newest event. A severity picked since the last refresh starts from
    /// now: what it would announce is recorded as announced, quietly, while the severities
    /// picked before go on as usual. Turning something on never announces what came before.
    public mutating func refreshed(
        feed: [Occurrence], isOn: Bool, rules: NotificationRules, readState: ReadState,
        now: Date
    ) -> [Occurrence] {
        let newest = AlertNotificationPlan.baseline(for: feed)
        let added = rules.severities.subtracting(severities ?? rules.severities)
        severities = rules.severities
        guard let baseline, isOn else {
            baseline = max(baseline ?? newest, newest)
            return []
        }
        if !added.isEmpty {
            var quiet = rules
            quiet.severities = added
            ledger.record(
                ledger.notifying(
                    in: feed, after: baseline, rules: quiet, readState: readState, now: now))
        }
        let notifying = ledger.notifying(
            in: feed, after: baseline, rules: rules, readState: readState, now: now)
        ledger.record(notifying)
        ledger.forget(before: now.addingTimeInterval(-7 * 24 * 3600))
        return notifying
    }
}

public enum AlertNotificationPlan {
    /// Up to this many notify one by one; more become one summary.
    public static let summaryLimit = 3

    /// Events at or before the baseline don't notify: the first refresh after launch sets
    /// it to the newest event it sees, so starting the app announces nothing old.
    public static func baseline(for feed: [Occurrence]) -> Date {
        feed.map(\.lastEventAt).max() ?? .distantPast
    }

    public static func delivery(of occurrences: [Occurrence]) -> NotificationDelivery {
        occurrences.count > summaryLimit ? .summary(occurrences) : .each(occurrences)
    }

    /// "5 critical alerts on onprem", "4 alerts on 2 instances": the summary's title.
    public static func summaryTitle(of occurrences: [Occurrence]) -> String {
        let severities = Set(occurrences.map(\.alert.severity))
        let kind = severities.count == 1 ? "\(severities.first?.rawValue ?? "") alerts" : "alerts"
        let instances = Set(occurrences.map(\.channel.instance))
        let place =
            instances.count == 1
            ? instances.first ?? "" : "\(instances.count) instances"
        return "\(occurrences.count) \(kind) on \(place)"
    }

    /// "CartServiceDown, HighErrorRate, BackupJobFailed and 2 more": the summary's body.
    public static func summaryBody(of occurrences: [Occurrence], naming count: Int = 3) -> String {
        let names = occurrences.prefix(count).map(\.alert.title).joined(separator: ", ")
        let rest = occurrences.count - min(count, occurrences.count)
        return rest > 0 ? "\(names) and \(rest) more" : names
    }
}
