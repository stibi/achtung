import Foundation

/// A channel with how much of it the user hasn't read yet.
public struct ChannelSummary: Sendable, Hashable, Identifiable {
    public let channel: Channel
    public let unread: Int
    /// Unread occurrences with severity critical.
    public let unreadCritical: Int

    public var id: ChannelID { channel.id }

    /// Nothing in the channel is unread; the sidebar greys it out.
    public var isAllRead: Bool { unread == 0 }
}

/// A sending system, typically one cluster's Alertmanager, with its channels (ADR 0006).
public struct Instance: Sendable, Hashable, Identifiable {
    public let name: String
    public let channels: [ChannelSummary]

    public var id: String { name }

    public var unread: Int { channels.reduce(0) { $0 + $1.unread } }
    public var unreadCritical: Int { channels.reduce(0) { $0 + $1.unreadCritical } }
    public var isAllRead: Bool { unread == 0 }

    /// The sidebar: each instance with its channels and their unread counts. Instances with
    /// something unread come first, then the rest, each group by name; channels inside an
    /// instance follow the same rule. `occurrences` must hold every occurrence that can be
    /// unread (the all-channels feed down to the read baseline); ones in channels the list
    /// doesn't have are ignored.
    public static func sidebar(
        channels: [Channel], occurrences: [Occurrence], readState: ReadState
    ) -> [Instance] {
        var unread: [ChannelID: Int] = [:]
        var unreadCritical: [ChannelID: Int] = [:]
        for occurrence in occurrences where !readState.isRead(occurrence) {
            unread[occurrence.channel, default: 0] += 1
            if occurrence.alert.severity == .critical {
                unreadCritical[occurrence.channel, default: 0] += 1
            }
        }
        let summaries = channels.map {
            ChannelSummary(
                channel: $0, unread: unread[$0.id] ?? 0, unreadCritical: unreadCritical[$0.id] ?? 0)
        }
        let byInstance = Dictionary(grouping: summaries) { $0.channel.id.instance }
        return byInstance.map { name, channels in
            Instance(
                name: name,
                channels: channels.sorted {
                    comesFirst(
                        ($0.isAllRead, $0.channel.id.slug), ($1.isAllRead, $1.channel.id.slug))
                })
        }
        .sorted { comesFirst(($0.isAllRead, $0.name), ($1.isAllRead, $1.name)) }
    }

    /// Something unread before all read, then by name.
    private static func comesFirst(
        _ lhs: (allRead: Bool, name: String), _ rhs: (allRead: Bool, name: String)
    ) -> Bool {
        if lhs.allRead != rhs.allRead {
            return !lhs.allRead
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
