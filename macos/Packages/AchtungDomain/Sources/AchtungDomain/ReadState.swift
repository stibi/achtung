import Foundation

/// What this client has seen. It lives only on this Mac (ADR 0002) and is keyed on the
/// server's `lastEventAt`: a fire, resolve or reopen makes an occurrence unread and new
/// again, a repeat notification doesn't. Every time stored here is a server time, so the
/// Mac's clock never matters.
public struct ReadState: Sendable, Codable, Equatable {
    /// For each occurrence the user opened, its `lastEventAt` at that moment.
    private var readUpTo: [Int: Date] = [:]
    /// For each channel, its `lastEventAt` when the user last looked at it.
    private var channelSeenUpTo: [ChannelID: Date] = [:]
    /// The newest event the client had loaded when the user last left the app. Anything
    /// later is new since then, including changes that arrived while the app was open but
    /// before a refresh fetched them.
    public private(set) var seenUntil: Date?
    /// Everything that last changed at or before this counts as read. Set once, to the
    /// newest event the client saw on its first launch with unread counts, so a backlog
    /// the user never opened one by one doesn't show up as unread.
    public private(set) var baseline: Date?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case readUpTo
        case channelSeenUpTo
        case seenUntil
        case baseline
    }

    /// Also reads the format from before channels had an instance (ADR 0006). Its channel
    /// visits were keyed by name alone; they're dropped rather than guessed into an
    /// instance, so those channels fall back to `seenUntil` until the user looks again.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readUpTo = try container.decode([Int: Date].self, forKey: .readUpTo)
        seenUntil = try container.decodeIfPresent(Date.self, forKey: .seenUntil)
        baseline = try container.decodeIfPresent(Date.self, forKey: .baseline)
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
    /// at or before the baseline. A fire, resolve or reopen after either makes it unread.
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
}
