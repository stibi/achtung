import AchtungDomain
import Foundation

enum Fixture {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func minutes(_ value: Double) -> Date {
        start.addingTimeInterval(value * 60)
    }

    static func channel(
        _ slug: String, instance: String = "onprem", firing: Int, lastEventAt: Date?
    ) -> Channel {
        Channel(
            id: ChannelID(instance: instance, slug: slug), firing: firing, lastEventAt: lastEventAt)
    }

    static func occurrence(
        id: Int, lastEventAt: Date,
        channel: ChannelID = ChannelID(instance: "onprem", slug: "infra"),
        severity: Severity = .critical
    ) -> Occurrence {
        Occurrence(
            id: id, channel: channel, source: "alertmanager",
            alert: IncomingAlert(
                sourceKey: "key-\(id)", severity: severity, title: "Alert \(id)", summary: nil,
                labels: [:], annotations: [:], startsAt: start, links: [], state: .firing),
            firstReceivedAt: start, lastReceivedAt: lastEventAt, lastEventAt: lastEventAt,
            notificationCount: 1)
    }
}
