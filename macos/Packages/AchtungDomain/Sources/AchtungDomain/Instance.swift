/// A sending system, typically one cluster's Alertmanager, with its channels (ADR 0006).
public struct Instance: Sendable, Hashable, Identifiable {
    public let name: String
    public let channels: [Channel]

    public var id: String { name }

    /// Occurrences firing in all of the instance's channels.
    public var firing: Int {
        channels.reduce(0) { $0 + $1.firing }
    }

    /// Groups channels by instance, keeping the order they come in (the server sorts by
    /// instance, then name).
    public static func grouping(_ channels: [Channel]) -> [Instance] {
        var names: [String] = []
        var byName: [String: [Channel]] = [:]
        for channel in channels {
            if byName[channel.id.instance] == nil {
                names.append(channel.id.instance)
            }
            byName[channel.id.instance, default: []].append(channel)
        }
        return names.map { Instance(name: $0, channels: byName[$0] ?? []) }
    }
}
