import Foundation

/// Which occurrences a list holds: every channel's (the Live view) or one channel's.
public enum OccurrenceScope: Hashable, Sendable {
    case allChannels
    case channel(ChannelID)
}

/// The occurrences in one `OccurrenceScope` as far as the client has loaded them, most
/// recently changed first, in the server's `(lastEventAt, id)` order.
public struct OccurrenceList: Sendable, Equatable {
    public private(set) var occurrences: [Occurrence] = []

    public init() {}

    /// How far back a refresh asks for changes: a minute before the newest change the list
    /// knows about. The server stamps `lastEventAt` before its transaction commits, so a
    /// change can become visible after a later-stamped one; without the overlap the client
    /// would never fetch it. `merge` makes the overlap harmless.
    public var refreshSince: Date? {
        occurrences.first?.lastEventAt.addingTimeInterval(-Self.refreshOverlap)
    }

    /// How far back of the newest known change a refresh asks again, and how far behind it
    /// the read baseline stays (`ReadState.advanceBaseline`), for changes committed late.
    public static let refreshOverlap: TimeInterval = 60

    /// Adds occurrences, replacing those already listed with the same id. Pages and
    /// refreshes can overlap, and an occurrence that changed moves to its new place.
    public mutating func merge(_ batch: [Occurrence]) {
        var byID = Dictionary(occurrences.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for occurrence in batch {
            byID[occurrence.id] = occurrence
        }
        occurrences = byID.values.sorted { ($0.lastEventAt, $0.id) > ($1.lastEventAt, $1.id) }
    }
}
