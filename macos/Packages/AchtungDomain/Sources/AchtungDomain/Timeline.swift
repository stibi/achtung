import Foundation

/// A span of time drawn top to bottom: position 0 is its end (now), position 1 its start.
public struct TimelineWindow: Sendable, Hashable {
    /// The Live timeline shows the last 24 hours.
    public static let span: TimeInterval = 24 * 3600

    public let end: Date
    public let start: Date

    public init(endingAt end: Date) {
        self.end = end
        self.start = end.addingTimeInterval(-Self.span)
    }

    /// Where `date` sits, from 0 (the end) to 1 (the start); nil outside the window.
    public func position(of date: Date) -> Double? {
        guard date >= start, date <= end else { return nil }
        return clampedPosition(of: date)
    }

    /// Like `position(of:)`, but a date outside the window is pinned to its nearest edge.
    public func clampedPosition(of date: Date) -> Double {
        let fraction = end.timeIntervalSince(date) / end.timeIntervalSince(start)
        return min(max(fraction, 0), 1)
    }

    /// Whole hours inside the window that are a multiple of `hours` in `calendar`'s time
    /// zone, newest first: the timeline's tick marks.
    public func ticks(every hours: Int, calendar: Calendar) -> [Date] {
        guard
            var hour = calendar.dateInterval(of: .hour, for: end)?.start
        else { return [] }
        var ticks: [Date] = []
        while hour >= start {
            if calendar.component(.hour, from: hour).isMultiple(of: hours) {
                ticks.append(hour)
            }
            hour = hour.addingTimeInterval(-3600)
        }
        return ticks
    }
}

/// Something that happened to an occurrence, placed on the timeline.
public struct TimelineMarker: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case fired
        case resolved
        /// Its last resend, the one that made it unread again. Earlier ones aren't known
        /// without its history.
        case resent
    }

    public let occurrence: Occurrence
    public let kind: Kind
    public let date: Date
    /// Where it sits in the window, from 0 (now) to 1 (the window's start).
    public let position: Double
    public let isUnread: Bool

    public var id: String { "\(occurrence.id)-\(kind)" }
}

/// When something of one severity was firing within the window: the firing times of all
/// its occurrences merged, so a few bars show what fired when, however many alerts there
/// are. Open to the top while something still fires.
public struct TimelineBar: Sendable, Hashable, Identifiable {
    public let severity: Severity
    /// The newer end of the bar (smaller position), 0 while it still fires.
    public let top: Double
    /// The older end of the bar, 1 when it started before the window.
    public let bottom: Double

    public var id: String { "\(severity)-\(top)-\(bottom)" }
    public var isOpen: Bool { top == 0 }
}

/// Markers so close together that they're drawn as one, with a count.
public struct TimelineCluster: Sendable, Hashable, Identifiable {
    /// Newest first.
    public let markers: [TimelineMarker]

    public var id: String { markers.map(\.id).joined(separator: "|") }
    /// How many markers it holds: an alert that fired and resolved within it counts twice.
    public var count: Int { markers.count }
    /// How many alerts its markers belong to.
    public var alertCount: Int { Set(markers.map(\.occurrence.id)).count }
    /// The marker clicking the cluster goes to.
    public var newest: TimelineMarker { markers[0] }
    /// Where the cluster is drawn: at its newest marker, so neighbouring clusters, which
    /// start at least the clustering gap apart, never overlap.
    public var position: Double { newest.position }
    public var hasUnread: Bool { markers.contains(where: \.isUnread) }
    /// The most severe of its markers, which gives the cluster its colour.
    public var severity: Severity {
        markers.map(\.occurrence.alert.severity).max(by: { $0.rank < $1.rank }) ?? .unknown
    }
}

/// The Live view's timeline: where occurrences fired, resolved and were resent within a
/// window.
public struct Timeline: Sendable {
    public let window: TimelineWindow
    /// Newest first.
    public let markers: [TimelineMarker]
    public let bars: [TimelineBar]

    /// `occurrences` should hold everything that changed within the window (the
    /// all-channels feed paged back to its start: an occurrence that fired or resolved in
    /// the window has its last event there) and everything still firing (an alert that
    /// started before the window and still fires has no event in it). Duplicates are
    /// fine: one occurrence counts once.
    public init(occurrences: [Occurrence], readState: ReadState, window: TimelineWindow) {
        self.window = window
        var markers: [TimelineMarker] = []
        var spans: [Severity: [(top: Double, bottom: Double)]] = [:]
        var seen: Set<Int> = []
        for occurrence in occurrences where seen.insert(occurrence.id).inserted {
            let isUnread = !readState.isRead(occurrence)
            let startsAt = occurrence.alert.startsAt
            let endsAt: Date? =
                if case .resolved(let endsAt) = occurrence.alert.state { endsAt } else { nil }
            let resentAt = occurrence.isResent ? occurrence.lastEventAt : nil
            let events: [(TimelineMarker.Kind, Date?)] = [
                (.fired, startsAt), (.resolved, endsAt), (.resent, resentAt),
            ]
            for (kind, date) in events {
                guard let date, let position = window.position(of: date) else { continue }
                markers.append(
                    TimelineMarker(
                        occurrence: occurrence, kind: kind, date: date, position: position,
                        isUnread: isUnread))
            }
            let barEnd = endsAt ?? window.end
            if startsAt <= window.end, barEnd >= window.start {
                spans[occurrence.alert.severity, default: []].append(
                    (window.clampedPosition(of: barEnd), window.clampedPosition(of: startsAt)))
            }
        }
        self.markers = markers.sorted { $0.position < $1.position }
        // Least severe first, so where bars overlap the more severe one is drawn on top.
        self.bars = spans.sorted { $0.key.rank < $1.key.rank }.flatMap { severity, spans in
            Self.merged(spans).map {
                TimelineBar(severity: severity, top: $0.top, bottom: $0.bottom)
            }
        }
    }

    /// Overlapping or touching spans joined into one.
    private static func merged(_ spans: [(top: Double, bottom: Double)]) -> [(
        top: Double, bottom: Double
    )] {
        var merged: [(top: Double, bottom: Double)] = []
        for span in spans.sorted(by: { $0.top < $1.top }) {
            if let last = merged.last, span.top <= last.bottom {
                merged[merged.count - 1].bottom = max(last.bottom, span.bottom)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Groups markers that are less than `gap` apart (as a fraction of the timeline's
    /// height) into clusters, top to bottom. Each cluster starts at its newest marker and
    /// takes the following ones within `gap` of it, so a long burst splits into several
    /// clusters rather than one that covers hours.
    public func clusters(gap: Double) -> [TimelineCluster] {
        var clusters: [TimelineCluster] = []
        var current: [TimelineMarker] = []
        for marker in markers {
            if let first = current.first, marker.position - first.position >= gap {
                clusters.append(TimelineCluster(markers: current))
                current = []
            }
            current.append(marker)
        }
        if !current.isEmpty {
            clusters.append(TimelineCluster(markers: current))
        }
        return clusters
    }
}

extension Severity {
    /// Critical first: orders severities for a cluster's colour.
    public var rank: Int {
        switch self {
        case .critical: 3
        case .warning: 2
        case .info: 1
        case .unknown: 0
        }
    }
}
