import Foundation

/// Which occurrences a macOS notification announces (ADR 0013): a new firing or a resend
/// (ADR 0009) after the baseline (ADR 0018), of a severity the user picked, not silenced, not read,
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

/// Per occurrence, the event a notification announced, so an event notifies once. Saved
/// with the baseline across launches (`AlertNotificationState.Saved`, ADR 0018).
public struct NotificationLedger: Sendable, Equatable, Codable {
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

/// What decides the notifications of one connection to a server: the baseline and the
/// ledger. Feed it each refresh; it returns what to announce. It is saved per server, so
/// what came while the app was closed notifies after a relaunch (ADR 0018).
public struct AlertNotificationState: Sendable {
    /// A saved state older than this is let go: back from a long break, start afresh.
    public static let restoreLimit: TimeInterval = 24 * 3600

    /// Events up to it don't notify. Nil until the first refresh, which only sets it.
    public private(set) var baseline: Date?
    public private(set) var ledger = NotificationLedger()
    /// The severities of the last refresh: a newly picked one starts from now too.
    private var severities: Set<Severity>?

    /// The state as saved between launches, with when it was saved.
    public struct Saved: Sendable, Equatable, Codable {
        public let baseline: Date
        public let ledger: NotificationLedger
        public let severities: Set<Severity>
        public let savedAt: Date
    }

    public init() {}

    /// Continues from a saved state, unless it's older than `restoreLimit` (or there is
    /// none): then the first refresh only sets the baseline, as on a first launch.
    public init(restoring saved: Saved?, now: Date) {
        guard let saved, now.timeIntervalSince(saved.savedAt) <= Self.restoreLimit else { return }
        baseline = saved.baseline
        ledger = saved.ledger
        severities = saved.severities
    }

    /// What to save; nil before the first refresh has set a baseline.
    public func saved(at now: Date) -> Saved? {
        baseline.map {
            Saved(baseline: $0, ledger: ledger, severities: severities ?? [], savedAt: now)
        }
    }

    /// After a refresh: the occurrences to announce, recorded as announced. The first
    /// refresh, and one while notifications are off or paused (`isOn` false), only move the
    /// baseline to the newest event. A severity picked since the last refresh starts from
    /// now: what it would announce is recorded as announced, quietly, while the severities
    /// picked before go on as usual. Turning something on never announces what came before.
    /// The occurrence the user is `viewing` counts as announced without being returned: no
    /// banner for what is already on screen, and none later for the same event. Events older
    /// than the ledger remembers (a week) never notify, however old the baseline.
    public mutating func refreshed(
        feed: [Occurrence], isOn: Bool, rules: NotificationRules, readState: ReadState,
        now: Date, viewing: Int? = nil
    ) -> [Occurrence] {
        let newest = AlertNotificationPlan.baseline(for: feed)
        let added = rules.severities.subtracting(severities ?? rules.severities)
        severities = rules.severities
        guard let baseline, isOn else {
            baseline = max(baseline ?? newest, newest)
            return []
        }
        // A restored baseline can be weeks old; the ledger forgets what is older than a week,
        // so that's as far back as anything may notify, or it would notify every refresh.
        let horizon = now.addingTimeInterval(-7 * 24 * 3600)
        let after = max(baseline, horizon)
        if !added.isEmpty {
            var quiet = rules
            quiet.severities = added
            ledger.record(
                ledger.notifying(
                    in: feed, after: after, rules: quiet, readState: readState, now: now))
        }
        let notifying = ledger.notifying(
            in: feed, after: after, rules: rules, readState: readState, now: now)
        ledger.record(notifying)
        ledger.forget(before: horizon)
        return notifying.filter { $0.id != viewing }
    }
}

public enum AlertNotificationPlan {
    /// Up to this many notify one by one; more become one summary.
    public static let summaryLimit = 3

    /// Events at or before the baseline don't notify: the first refresh without a saved
    /// state (ADR 0018) sets it to the newest event it sees, so it announces nothing old.
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
