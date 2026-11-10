import Foundation

/// An occurrence as Markdown to paste into an agent's prompt for investigation: what fires
/// and where, its times in ISO 8601 UTC, the summary and description, every annotation and
/// label, the links, its identity in its source and in Achtung, and its history when known.
/// Labels are `key=value` lines in a code block, ready for a selector. Only what the alert
/// itself carries; nothing from the user's Mac.
public enum AgentReport {
    /// `events` is the occurrence's history, oldest first, when it has loaded. `now`
    /// decides whether a silence is still on.
    public static func markdown(
        for occurrence: Occurrence, events: [OccurrenceEvent]? = nil, now: Date = .now
    ) -> String {
        let alert = occurrence.alert
        var sections = ["# \(alert.title)", facts(occurrence, now: now)]
        if let summary = alert.summary, !summary.isEmpty {
            sections.append("## Summary\n\n\(summary)")
        }
        if let description = alert.alertDescription, description != alert.summary {
            sections.append("## Description\n\n\(description)")
        }
        let links =
            alert.links.map { "- \($0.kind.rawValue.capitalized): \($0.url.absoluteString)" }
            + alert.linkAnnotations.map {
                "- \(linkTitle(forAnnotation: $0.name)) (`\($0.name)`): \($0.url.absoluteString)"
            }
        if !links.isEmpty {
            sections.append("## Links\n\n" + links.joined(separator: "\n"))
        }
        let annotations = alert.annotations.filter {
            $0.key != "summary" && $0.key != "description"
        }
        if !annotations.isEmpty {
            let entries = annotations.sorted { $0.key < $1.key }.map { name, value in
                "- `\(name)`: " + value.replacingOccurrences(of: "\n", with: "\n  ")
            }
            sections.append("## Annotations\n\n" + entries.joined(separator: "\n"))
        }
        if !alert.labels.isEmpty {
            let lines = alert.labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            let fence = fence(around: lines)
            sections.append(
                "## Labels\n\n\(fence)\n" + lines.joined(separator: "\n") + "\n\(fence)")
        }
        if let events, !events.isEmpty {
            let lines = events.map { event in
                "- \(iso(event.recordedAt)) \(event.kind.rawValue)"
                    + (event.cause == .vanished
                        ? " (gone from Alertmanager: Achtung resolved it itself, Alertmanager "
                            + "never sent the resolve)" : "")
            }
            sections.append("## History\n\n" + lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func facts(_ occurrence: Occurrence, now: Date) -> String {
        let alert = occurrence.alert
        var lines = [
            "- State: \(state(of: occurrence, now: now))",
            "- Severity: \(alert.severity.rawValue)",
            "- Source: \(occurrence.source), instance `\(occurrence.channel.instance)`, "
                + "channel `#\(occurrence.channel.slug)`",
            "- Started: \(iso(alert.startsAt))",
        ]
        if case .resolved(let endsAt) = alert.state {
            lines.append("- Resolved: \(iso(endsAt))")
        }
        let count = occurrence.notificationCount
        let notifications = "\(count) notification" + (count == 1 ? "" : "s")
        let first = iso(occurrence.firstReceivedAt)
        let last = iso(occurrence.lastReceivedAt)
        lines += [
            "- Last event: \(occurrence.lastEventKind.rawValue) at \(iso(occurrence.lastEventAt))",
            "- Received: first \(first), last \(last), \(notifications)",
            "- Source key (fingerprint): `\(alert.sourceKey)`",
            "- Achtung occurrence: \(occurrence.id)",
        ]
        return lines.joined(separator: "\n")
    }

    /// "firing", "resolved", with "resent" and "silenced until …" when they apply.
    private static func state(of occurrence: Occurrence, now: Date) -> String {
        var parts = [occurrence.alert.isFiring ? "firing" : "resolved"]
        if occurrence.isResent {
            parts.append("resent")
        }
        if occurrence.isSilenced(at: now), let until = occurrence.silencedUntil {
            parts.append("silenced until \(iso(until))")
        }
        return parts.joined(separator: ", ")
    }

    /// Backticks one longer than the longest run in `lines`, at least three, so a value
    /// with backticks can't close the code block.
    private static func fence(around lines: [String]) -> String {
        var longest = 0
        for line in lines {
            var run = 0
            for character in line {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// "2026-11-10T08:15:00Z": UTC, to the second.
    static func iso(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC") ?? .gmt))
    }
}
