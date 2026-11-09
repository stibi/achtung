import Foundation

/// A silence active on an Alertmanager.
public struct Silence: Sendable, Hashable, Identifiable {
    public struct Matcher: Sendable, Hashable {
        public let name: String
        public let value: String
        public let isRegex: Bool
        /// False negates the match (!= or !~).
        public let isEqual: Bool

        public init(name: String, value: String, isRegex: Bool, isEqual: Bool) {
            self.name = name
            self.value = value
            self.isRegex = isRegex
            self.isEqual = isEqual
        }

        /// "namespace=prod", "pod=~api-.*", "env!=dev".
        public var text: String {
            let operation =
                switch (isEqual, isRegex) {
                case (true, false): "="
                case (true, true): "=~"
                case (false, false): "!="
                case (false, true): "!~"
                }
            return name + operation + value
        }
    }

    public let instance: String
    /// Alertmanager's id, unique within its instance.
    public let silenceID: String
    public let endsAt: Date
    public let createdBy: String
    public let comment: String
    public let matchers: [Matcher]

    public var id: String { "\(instance)/\(silenceID)" }

    public init(
        instance: String, silenceID: String, endsAt: Date, createdBy: String, comment: String,
        matchers: [Matcher]
    ) {
        self.instance = instance
        self.silenceID = silenceID
        self.endsAt = endsAt
        self.createdBy = createdBy
        self.comment = comment
        self.matchers = matchers
    }

    /// What it silences, short: the alertname it matches, then up to two other matchers,
    /// "HighErrorRate · namespace=prod, service=api"; "and 2 more" when there are more.
    public var summary: String {
        let alertname = matchers.first { $0.name == "alertname" && $0.isEqual && !$0.isRegex }
        let others = matchers.filter { $0 != alertname }
        var labels = others.prefix(2).map(\.text).joined(separator: ", ")
        if others.count > 2 {
            labels += " and \(others.count - 2) more"
        }
        switch (alertname?.value, labels.isEmpty) {
        case (let name?, true): return name
        case (let name?, false): return "\(name) · \(labels)"
        case (nil, _): return labels.isEmpty ? "Everything" : labels
        }
    }
}
