import AchtungDomain
import Foundation

enum Fixture {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func minutes(_ value: Double) -> Date {
        start.addingTimeInterval(value * 60)
    }

    static func occurrence(id: Int, lastEventAt: Date) -> Occurrence {
        Occurrence(
            id: id, channel: "infra", source: "alertmanager",
            alert: IncomingAlert(
                sourceKey: "key-\(id)", severity: .critical, title: "Alert \(id)", summary: nil,
                labels: [:], annotations: [:], startsAt: start, links: [], state: .firing),
            firstReceivedAt: start, lastReceivedAt: lastEventAt, lastEventAt: lastEventAt,
            notificationCount: 1)
    }
}
