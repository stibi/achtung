import AchtungDomain
import Foundation

/// Placeholder until alerts come from the server API.
struct Channel {
    let name: String
    let alerts: [IncomingAlert]
}

enum SampleData {
    static let channels = [
        Channel(
            name: "infra",
            alerts: [
                IncomingAlert(
                    sourceKey: "a1b2c3",
                    severity: .critical,
                    title: "NodeDown",
                    summary: "node-1 has been unreachable for 5 minutes.",
                    labels: ["alertname": "NodeDown", "instance": "node-1"],
                    annotations: ["summary": "node-1 has been unreachable for 5 minutes."],
                    startsAt: Date(timeIntervalSinceNow: -300),
                    links: [
                        AlertLink(kind: .runbook, url: URL(filePath: "/runbooks/node-down"))
                    ],
                    state: .firing
                ),
                IncomingAlert(
                    sourceKey: "d4e5f6",
                    severity: .warning,
                    title: "DiskFillingUp",
                    summary: nil,
                    labels: ["alertname": "DiskFillingUp", "instance": "node-2"],
                    annotations: [:],
                    startsAt: Date(timeIntervalSinceNow: -7200),
                    links: [],
                    state: .resolved(endsAt: Date(timeIntervalSinceNow: -600))
                ),
            ]
        ),
        Channel(name: "apps", alerts: []),
    ]
}
