import Foundation

/// The alert names Home leaves out of each Alertmanager's counts, its alert list and its
/// delivery check: one list on the server, shared by every user (ADR 0002). Channels and
/// Live show these alerts as usual. Matched exactly against the alertname label.
/// The server checks the limits (200 names of up to 200 characters) and says what's wrong.
public enum IgnoredAlertNames {
    /// `names` with `name` added, trimmed and sorted as the server keeps them; nil when
    /// the trimmed name is empty or already there, so there's nothing to save.
    public static func adding(_ name: String, to names: [String]) -> [String]? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !names.contains(trimmed) else { return nil }
        return (names + [trimmed]).sorted()
    }
}
