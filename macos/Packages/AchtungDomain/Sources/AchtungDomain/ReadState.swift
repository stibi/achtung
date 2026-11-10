import Foundation

/// What this client has seen. It lives only on this Mac (ADR 0002) and is keyed on the
/// server's `lastEventAt`: a fire, resolve, reopen or resend (the server's hourly record of
/// a repeat for an alert that still fires) makes an occurrence unread again; other repeat
/// notifications don't. Every time stored here is a server time, so the Mac's clock never
/// matters.
public struct ReadState: Sendable, Codable, Equatable {
    /// For each occurrence the user opened, its `lastEventAt` at that moment.
    private var readUpTo: [Int: Date] = [:]
    /// For each channel, its `lastEventAt` when the user last looked at it.
    private var channelSeenUpTo: [ChannelID: Date] = [:]
    /// The newest event the client had loaded when the user last left the app. Anything
    /// later is new since then, including changes that arrived while the app was open but
    /// before a refresh fetched them.
    public private(set) var seenUntil: Date?
    /// Everything that last changed at or before this counts as read. First set to the
    /// newest event on the server at the first launch with unread counts, so a backlog the
    /// user never opened one by one doesn't show up as unread; `advanceBaseline` then moves
    /// it forward.
    public private(set) var baseline: Date?
    /// Channels whose list shows read alerts too. Every other channel hides them, so the
    /// default is on and only the exceptions are stored.
    private var showsReadIn: Set<ChannelID> = []
    /// Whether Live shows read alerts too; it hides them unless the user said otherwise.
    private var showsReadInLive = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case readUpTo
        case channelSeenUpTo
        case seenUntil
        case baseline
        case showsReadIn
        case showsReadInLive
    }

    /// Also reads the format from before channels had an instance (ADR 0006). Its channel
    /// visits were keyed by name alone; they're dropped rather than guessed into an
    /// instance, so those channels fall back to `seenUntil` until the user looks again.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readUpTo = try container.decode([Int: Date].self, forKey: .readUpTo)
        seenUntil = try container.decodeIfPresent(Date.self, forKey: .seenUntil)
        baseline = try container.decodeIfPresent(Date.self, forKey: .baseline)
        showsReadIn =
            try container.decodeIfPresent(Set<ChannelID>.self, forKey: .showsReadIn) ?? []
        showsReadInLive =
            try container.decodeIfPresent(Bool.self, forKey: .showsReadInLive) ?? false
        do {
            channelSeenUpTo = try container.decode(
                [ChannelID: Date].self, forKey: .channelSeenUpTo)
        } catch DecodingError.typeMismatch
            where (try? container.decode([String: Date].self, forKey: .channelSeenUpTo)) != nil
        {
            channelSeenUpTo = [:]
        }
    }

    public mutating func markRead(_ occurrence: Occurrence) {
        readUpTo[occurrence.id] = max(
            readUpTo[occurrence.id] ?? .distantPast, occurrence.lastEventAt)
    }

    /// Read when the user opened it at its current `lastEventAt`, or when it last changed
    /// at or before the baseline. A fire, resolve, reopen or resend after either makes it
    /// unread.
    public func isRead(_ occurrence: Occurrence) -> Bool {
        if let baseline, occurrence.lastEventAt <= baseline {
            return true
        }
        guard let readAt = readUpTo[occurrence.id] else { return false }
        return readAt >= occurrence.lastEventAt
    }

    /// Sets the baseline on the first launch with unread counts, including after a
    /// migration from a stored state that has none. Later calls change nothing.
    public mutating func setBaselineIfMissing(_ latestEventAt: Date) {
        if baseline == nil {
            baseline = latestEventAt
        }
    }

    /// Moves the baseline up once the all-channels feed reaches back to it, so the backlog
    /// each launch pages through doesn't keep growing. `feed` is what's loaded of the feed,
    /// `hasOlder` whether older pages remain. The feed reaches back when nothing older is
    /// left or its oldest change is at or before the baseline; otherwise (stopped at the
    /// cap, or interrupted) the oldest unread may not be loaded, and nothing moves.
    ///
    /// The new baseline is just before the oldest unread occurrence, never later than the
    /// newest loaded change minus `OccurrenceList.refreshOverlap` (a change the server
    /// commits late stays above it), and never back.
    ///
    /// Read marks at or below the new baseline are dropped, which can't change `isRead`: a
    /// mark only ever makes an occurrence read whose `lastEventAt` is at or below the mark,
    /// and the baseline already covers all of those.
    @discardableResult
    public mutating func advanceBaseline(over feed: [Occurrence], hasOlder: Bool) -> Bool {
        guard let current = baseline, let newest = feed.map(\.lastEventAt).max(),
            let oldest = feed.map(\.lastEventAt).min(), !hasOlder || oldest <= current
        else { return false }
        let ceiling = newest.addingTimeInterval(-OccurrenceList.refreshOverlap)
        let oldestUnread = feed.filter { !isRead($0) }.map(\.lastEventAt).min()
        // Just before: the oldest unread itself must stay above the baseline.
        let target = min(ceiling, oldestUnread?.addingTimeInterval(-0.001) ?? ceiling)
        guard target > current else { return false }
        baseline = target
        readUpTo = readUpTo.filter { $0.value > target }
        return true
    }

    /// The first unread occurrence of a list sorted newest change first, or nil.
    public func firstUnread(in occurrences: [Occurrence]) -> Occurrence? {
        occurrences.first { !isRead($0) }
    }

    /// The user left the app having loaded events up to `latestEventAt`.
    public mutating func markSeen(upTo latestEventAt: Date) {
        seenUntil = max(seenUntil ?? .distantPast, latestEventAt)
    }

    /// Changed since the user last left the app. Before their first visit, nothing is.
    public func isNew(_ occurrence: Occurrence) -> Bool {
        guard let seenUntil else { return false }
        return occurrence.lastEventAt > seenUntil
    }

    /// The user is looking at `channel` as the server last described it.
    public mutating func markVisited(_ channel: Channel) {
        guard let lastEventAt = channel.lastEventAt else { return }
        channelSeenUpTo[channel.id] = max(
            channelSeenUpTo[channel.id] ?? .distantPast, lastEventAt)
    }

    /// Something happened in the channel since the user last looked at it, or, for a
    /// channel they never opened, since they last left the app.
    public func hasNews(_ channel: Channel) -> Bool {
        guard let lastEventAt = channel.lastEventAt,
            let seen = channelSeenUpTo[channel.id] ?? seenUntil
        else { return false }
        return lastEventAt > seen
    }

    /// Whether a list hides read alerts, showing only new ones and resends: each channel's
    /// and Live's on its own. On unless the user turned it off there.
    public func hidesRead(in scope: OccurrenceScope) -> Bool {
        switch scope {
        case .allChannels: !showsReadInLive
        case .channel(let id): !showsReadIn.contains(id)
        // Search results are everything that matches, read or not.
        case .search: false
        }
    }

    public mutating func setHidesRead(_ hides: Bool, in scope: OccurrenceScope) {
        switch scope {
        case .allChannels:
            showsReadInLive = !hides
        case .channel(let id) where hides:
            showsReadIn.remove(id)
        case .channel(let id):
            showsReadIn.insert(id)
        case .search:
            break
        }
    }

    /// What a list shows. `own` is the list as far as it's loaded, `feed` the all-channels
    /// feed, which holds every unread occurrence down to the baseline (for Live, `own` is
    /// the feed). Showing read alerts, the list is `own`. Hiding them, it's the unread ones
    /// (new alerts and resends) of both that belong to `scope`, so a channel's list matches
    /// the sidebar's count without older pages. Either way it keeps `kept`, the occurrence
    /// the user has open (a channel's selection, Live's last clicked card): opening one
    /// marks it read, and it must not vanish while the user reads it, nor when they turn
    /// hiding off while it came from the feed. It drops out once they move on; a later
    /// resend brings it back as unread.
    ///
    /// Where both hold an occurrence, the copy with the later `lastEventAt` counts: either
    /// list can be behind (a channel's is refreshed only while it's open). On a tie, the
    /// list's own copy, which a silence updates too.
    public func shown(
        own: [Occurrence], feed: [Occurrence], in scope: OccurrenceScope, keeping kept: Int?
    ) -> [Occurrence] {
        let byID = Self.latest(own: own, feed: feed, in: scope)
        var list = OccurrenceList()
        if hidesRead(in: scope) {
            list.merge(byID.values.filter { !isRead($0) || $0.id == kept })
        } else {
            list.merge(own.map { byID[$0.id] ?? $0 })
            if let kept, !own.contains(where: { $0.id == kept }), let occurrence = byID[kept] {
                list.merge([occurrence])
            }
        }
        return list.occurrences
    }

    /// The unread occurrences of a list (see `shown` for `own` and `feed`), each in its
    /// latest copy: what the list shows with read alerts hidden, and what "Mark All as
    /// Read" marks. That's the badge's set, plus the rare one only the list has newer: a
    /// change between a refresh's feed and list loads, or one past the feed's cap.
    public func unread(own: [Occurrence], feed: [Occurrence], in scope: OccurrenceScope)
        -> [Occurrence]
    {
        Self.latest(own: own, feed: feed, in: scope).values.filter { !isRead($0) }
    }

    /// Marks what is unread in a list read, each occurrence at the `lastEventAt` the client
    /// has loaded, rather than moving a baseline to now: whatever changed after the last
    /// refresh, which the client hasn't seen, stays unread, and so does any later change.
    public mutating func markAllRead(
        own: [Occurrence], feed: [Occurrence], in scope: OccurrenceScope
    ) {
        for occurrence in unread(own: own, feed: feed, in: scope) {
            markRead(occurrence)
        }
    }

    /// Each occurrence of `scope` in the list or the feed, in its copy with the later
    /// `lastEventAt`, or on a tie the list's own.
    private static func latest(own: [Occurrence], feed: [Occurrence], in scope: OccurrenceScope)
        -> [Int: Occurrence]
    {
        var byID: [Int: Occurrence] = [:]
        for occurrence in feed where scope.contains(occurrence) {
            byID[occurrence.id] = occurrence
        }
        for occurrence in own
        where occurrence.lastEventAt >= byID[occurrence.id]?.lastEventAt ?? .distantPast {
            byID[occurrence.id] = occurrence
        }
        return byID
    }
}
