import Foundation

/// Whether Grafana IRM receives the heartbeat an Alertmanager sends it: the pipeline
/// checked past Alertmanager, next to its Watchdog. The server reads IRM at most once a
/// minute. The texts take a `time` formatter, which the app gives its own.
public struct IrmHeartbeat: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// As IRM was last read successfully, at `checkedAt`.
        case known(Known, checkedAt: Date)
        /// IRM was never read successfully.
        case unknown
    }

    public enum Known: Sendable, Hashable {
        /// IRM has no open missed-heartbeat alert group; the last one it resolved, if any.
        case receiving(lastMissed: Missed?)
        /// IRM has an open missed-heartbeat alert group, opened at `since`.
        case missing(since: Date)
    }

    /// A missed heartbeat that IRM resolved.
    public struct Missed: Sendable, Hashable {
        public let start: Date
        public let end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
    }

    /// How the heart looks: green, red, or grey.
    public enum Tone: Sendable, Hashable {
        case good
        case bad
        case unknown
    }

    public let status: Status
    /// Why the latest read of IRM failed; nil when it worked.
    public let error: String?

    public init(status: Status, error: String?) {
        self.status = status
        self.error = error
    }

    public var tone: Tone {
        switch status {
        case .known(.receiving, _): .good
        case .known(.missing, _): .bad
        case .unknown: .unknown
        }
    }

    /// The latest read failed, so the status is from an earlier one: the heart dims.
    public var isStale: Bool {
        if case .known = status { error != nil } else { false }
    }

    /// "IRM missing the heartbeat since 14:05": shown on the tile itself, not only in the
    /// help, because it's a real problem. Nil unless missing.
    public func warning(time: (Date) -> String) -> String? {
        guard case .known(.missing(let since), _) = status else { return nil }
        return "IRM missing the heartbeat since \(time(since))"
    }

    /// "Grafana IRM is receiving the heartbeat. Last missed 8 Nov 16:52, for 2m.", with
    /// the failed read's error when there is one.
    public func help(time: (Date) -> String) -> String {
        let status =
            switch status {
            case .known(.receiving(let missed?), _):
                "Grafana IRM is receiving the heartbeat. Last missed \(time(missed.start)), "
                    + "for \(shortDuration(missed.end.timeIntervalSince(missed.start)))."
            case .known(.receiving(nil), _):
                "Grafana IRM is receiving the heartbeat. Never missed."
            case .known(.missing(let since), _):
                "Grafana IRM is missing the heartbeat since \(time(since)): it isn't getting "
                    + "it from this Alertmanager."
            case .unknown:
                "Grafana IRM's heartbeat is unknown: IRM was never read."
            }
        return [status, readProblem(time: time)].compactMap(\.self).joined(separator: " ")
    }

    /// For VoiceOver, in the tile's label: "IRM receiving", "IRM missing the heartbeat
    /// since 14:05", "IRM unknown", with "as of 14:03" when stale.
    public func accessibilityText(time: (Date) -> String) -> String {
        switch status {
        case .known(let known, let checkedAt):
            let text =
                switch known {
                case .receiving: "IRM receiving"
                case .missing(let since): "IRM missing the heartbeat since \(time(since))"
                }
            return error == nil ? text : "\(text), as of \(time(checkedAt))"
        case .unknown:
            return "IRM unknown"
        }
    }

    private func readProblem(time: (Date) -> String) -> String? {
        guard let error else { return nil }
        guard case .known(_, let checkedAt) = status else { return "Reading IRM failed: \(error)." }
        return "IRM couldn't be read just now (\(error)); this is from \(time(checkedAt))."
    }
}
