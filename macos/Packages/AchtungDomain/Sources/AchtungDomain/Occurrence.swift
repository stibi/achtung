import Foundation

/// A channel's identity. A channel name is unique only within its instance, the sending
/// system it belongs to (ADR 0006), so two instances can each have a `devops` channel.
public struct ChannelID: Sendable, Hashable, Codable {
    public let instance: String
    public let slug: String

    public init(instance: String, slug: String) {
        self.instance = instance
        self.slug = slug
    }
}

/// A named stream of alerts, with what is firing in it. Mirrors the server's `Channel`.
public struct Channel: Sendable, Hashable, Identifiable {
    public let id: ChannelID
    /// Occurrences in the channel that are firing now.
    public let firing: Int
    /// The latest event in the channel; nil while it has none.
    public let lastEventAt: Date?

    public init(id: ChannelID, firing: Int, lastEventAt: Date?) {
        self.id = id
        self.firing = firing
        self.lastEventAt = lastEventAt
    }
}

/// An occurrence as the server stores it: what the source reported plus what Achtung
/// tracks. Mirrors `server/src/domain/occurrence.ts`.
public struct Occurrence: Sendable, Hashable, Identifiable {
    public let id: Int
    public let channel: ChannelID
    public let source: String
    public let alert: IncomingAlert
    public let firstReceivedAt: Date
    public let lastReceivedAt: Date
    /// When it last fired, resolved or reopened. Repeat notifications don't move it.
    public let lastEventAt: Date
    public let notificationCount: Int
    /// When the Alertmanager silence muting this alert ends; nil when none does, or when
    /// the server couldn't ask its Alertmanager (ADR 0008). Nil means not silenced.
    public let silencedUntil: Date?

    public init(
        id: Int,
        channel: ChannelID,
        source: String,
        alert: IncomingAlert,
        firstReceivedAt: Date,
        lastReceivedAt: Date,
        lastEventAt: Date,
        notificationCount: Int,
        silencedUntil: Date? = nil
    ) {
        self.id = id
        self.channel = channel
        self.source = source
        self.alert = alert
        self.firstReceivedAt = firstReceivedAt
        self.lastReceivedAt = lastReceivedAt
        self.lastEventAt = lastEventAt
        self.notificationCount = notificationCount
        self.silencedUntil = silencedUntil
    }

    /// Muted by an Alertmanager silence at `now`. A silence that ended since the last
    /// refresh no longer counts.
    public func isSilenced(at now: Date) -> Bool {
        guard let silencedUntil else { return false }
        return silencedUntil > now
    }
}

/// Something that happened to an occurrence. Events make up an alert's history.
public struct OccurrenceEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case fired
        case resolved
        case reopened
    }

    public let id: Int
    public let kind: Kind
    public let recordedAt: Date

    public init(id: Int, kind: Kind, recordedAt: Date) {
        self.id = id
        self.kind = kind
        self.recordedAt = recordedAt
    }
}

/// One occurrence with its history and the alert's other occurrences.
public struct OccurrenceDetail: Sendable, Hashable {
    public let occurrence: Occurrence
    /// Oldest first.
    public let events: [OccurrenceEvent]
    /// Other occurrences of the same alert, newest first.
    public let otherOccurrences: [Occurrence]

    public init(
        occurrence: Occurrence, events: [OccurrenceEvent], otherOccurrences: [Occurrence]
    ) {
        self.occurrence = occurrence
        self.events = events
        self.otherOccurrences = otherOccurrences
    }
}
