import AchtungDomain
import Foundation

/// Data for SwiftUI previews. The app itself shows what the server returns.
enum SampleData {
    private static let now = Date.now

    static let occurrences = [
        occurrence(id: 2, severity: .critical, title: "TargetDown", minutesAgo: 5, state: .firing),
        occurrence(
            id: 1, severity: .warning, title: "DiskFillingUp", minutesAgo: 90,
            state: .resolved(endsAt: now.addingTimeInterval(-90 * 60))),
    ]

    /// The user last looked 10 minutes ago and has opened the resolved occurrence.
    static var readState: ReadState {
        var state = ReadState()
        state.markSeen(upTo: now.addingTimeInterval(-600))
        state.markRead(occurrences[1])
        return state
    }

    private static func occurrence(
        id: Int, severity: Severity, title: String, minutesAgo: Double, state: AlertState
    ) -> Occurrence {
        let eventAt = now.addingTimeInterval(-minutesAgo * 60)
        let summary = "\(title) on node-\(id)."
        return Occurrence(
            id: id, channel: ChannelID(instance: "onprem", slug: "infra"), source: "alertmanager",
            alert: IncomingAlert(
                sourceKey: "sample-\(id)", severity: severity, title: title, summary: summary,
                labels: ["alertname": title, "instance": "node-\(id)"],
                annotations: ["summary": summary], startsAt: eventAt, links: [], state: state),
            firstReceivedAt: eventAt, lastReceivedAt: eventAt, lastEventAt: eventAt,
            lastEventKind: state == .firing ? .fired : .resolved, notificationCount: 1)
    }
}
