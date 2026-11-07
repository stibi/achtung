import Foundation

/// One occurrence of an alert: its identity plus when it started. A re-fire after resolve
/// has a new `startsAt`, so it is a new occurrence.
public struct OccurrenceID: Hashable, Sendable {
    let channel: String
    let sourceKey: String
    let startsAt: Date

    // Written out instead of synthesized: Periphery can't see synthesized code read the
    // fields and would report them as unused.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.channel, lhs.sourceKey, lhs.startsAt) == (rhs.channel, rhs.sourceKey, rhs.startsAt)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(channel)
        hasher.combine(sourceKey)
        hasher.combine(startsAt)
    }
}

/// An occurrence as this client received it.
public struct InboxEntry: Sendable, Identifiable {
    public let channel: String
    public let alert: IncomingAlert
    /// When this client first received the occurrence. Updates keep the original time.
    public let receivedAt: Date

    public var id: OccurrenceID {
        OccurrenceID(channel: channel, sourceKey: alert.sourceKey, startsAt: alert.startsAt)
    }
}

/// What this client has received and seen. Read state is local to each client (ADR 0002).
public struct Inbox: Sendable {
    public let channels: [String]
    /// Newest first, by `receivedAt`.
    public private(set) var entries: [InboxEntry] = []
    /// When the user last left the app. Entries received later are new since last time.
    public private(set) var seenUntil: Date?
    private var readIDs: Set<OccurrenceID> = []

    public init(channels: [String], seenUntil: Date?) {
        self.channels = channels
        self.seenUntil = seenUntil
    }

    /// Adds a new occurrence. A repeat notification or a resolution of a known occurrence
    /// updates it in place and doesn't make it new or unread again.
    public mutating func receive(_ alert: IncomingAlert, in channel: String, at time: Date) {
        let entry = InboxEntry(channel: channel, alert: alert, receivedAt: time)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = InboxEntry(
                channel: channel, alert: alert, receivedAt: entries[index].receivedAt)
        } else {
            let index = entries.firstIndex { $0.receivedAt < time } ?? entries.endIndex
            entries.insert(entry, at: index)
        }
    }

    public func entries(in channel: String) -> [InboxEntry] {
        entries.filter { $0.channel == channel }
    }

    public mutating func markRead(_ id: OccurrenceID) {
        readIDs.insert(id)
    }

    public func isRead(_ id: OccurrenceID) -> Bool {
        readIDs.contains(id)
    }

    public var unreadCount: Int {
        entries.count { !isRead($0.id) }
    }

    public func unreadCount(in channel: String) -> Int {
        entries.count { $0.channel == channel && !isRead($0.id) }
    }

    public mutating func markSeen(at time: Date) {
        seenUntil = time
    }

    public func isNew(_ entry: InboxEntry) -> Bool {
        guard let seenUntil else { return false }
        return entry.receivedAt > seenUntil
    }
}
