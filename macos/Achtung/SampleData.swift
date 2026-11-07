import AchtungDomain
import Foundation

/// Placeholder until alerts come from the server API and its event stream.
enum SampleData {
    private static let launch = Date.now

    /// Alerts that arrived over the last day. The user last looked 10 minutes ago, so the
    /// newest one shows as new.
    static func inbox() -> Inbox {
        var inbox = Inbox(
            channels: ["infra", "databases", "apps"],
            seenUntil: launch.addingTimeInterval(-600))
        for (alert, channel) in [
            (nodeDown, "infra"), (certificateExpiring, "infra"), (diskFillingUp, "infra"),
            (replicationLag, "databases"),
        ] {
            inbox.receive(alert, in: channel, at: alert.startsAt)
        }
        return inbox
    }

    /// Stands in for the server's event stream: delivers an alert every 8 seconds, one of
    /// them a resolution of an alert that is already in the inbox.
    @MainActor
    static func feed(deliver: (IncomingAlert, String) -> Void) async {
        let arrivals: [(String, (Date) -> IncomingAlert)] = [
            ("apps", { highErrorRate(startsAt: $0) }),
            ("infra", { resolved(nodeDown, at: $0) }),
            ("databases", { backupFailed(startsAt: $0) }),
        ]
        for (channel, makeAlert) in arrivals {
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return  // Cancelled: the window closed.
            }
            deliver(makeAlert(.now), channel)
        }
    }

    private static let nodeDown = IncomingAlert(
        sourceKey: "a1b2c3",
        severity: .critical,
        title: "NodeDown",
        summary: "node-1 has been unreachable for 5 minutes.",
        labels: ["alertname": "NodeDown", "instance": "node-1", "job": "node"],
        annotations: ["description": "Node exporter on node-1 stopped responding."],
        startsAt: launch.addingTimeInterval(-300),
        links: [
            AlertLink(kind: .runbook, url: URL(filePath: "/runbooks/node-down")),
            AlertLink(kind: .dashboard, url: URL(filePath: "/dashboards/nodes")),
        ],
        state: .firing
    )

    private static let certificateExpiring = IncomingAlert(
        sourceKey: "c7d8e9",
        severity: .info,
        title: "CertificateExpiringSoon",
        summary: "The TLS certificate for the ingress expires in 14 days.",
        labels: ["alertname": "CertificateExpiringSoon", "namespace": "ingress"],
        annotations: [:],
        startsAt: launch.addingTimeInterval(-86_400),
        links: [],
        state: .firing
    )

    private static let diskFillingUp = IncomingAlert(
        sourceKey: "d4e5f6",
        severity: .warning,
        title: "DiskFillingUp",
        summary: "/var on node-2 will be full within 24 hours.",
        labels: ["alertname": "DiskFillingUp", "instance": "node-2"],
        annotations: [:],
        startsAt: launch.addingTimeInterval(-7200),
        links: [],
        state: .resolved(endsAt: launch.addingTimeInterval(-900))
    )

    private static let replicationLag = IncomingAlert(
        sourceKey: "f0a1b2",
        severity: .warning,
        title: "ReplicationLagHigh",
        summary: "The postgres replica is 45 seconds behind the primary.",
        labels: ["alertname": "ReplicationLagHigh", "cluster": "postgres-main"],
        annotations: [:],
        startsAt: launch.addingTimeInterval(-1500),
        links: [],
        state: .firing
    )

    private static func highErrorRate(startsAt: Date) -> IncomingAlert {
        IncomingAlert(
            sourceKey: "e1e2e3",
            severity: .critical,
            title: "HighErrorRate",
            summary: "5% of checkout requests fail with HTTP 500.",
            labels: ["alertname": "HighErrorRate", "service": "checkout"],
            annotations: [:],
            startsAt: startsAt,
            links: [],
            state: .firing
        )
    }

    private static func backupFailed(startsAt: Date) -> IncomingAlert {
        IncomingAlert(
            sourceKey: "b9b8b7",
            severity: .critical,
            title: "BackupFailed",
            summary: "The nightly postgres backup did not complete.",
            labels: ["alertname": "BackupFailed", "cluster": "postgres-main"],
            annotations: [:],
            startsAt: startsAt,
            links: [],
            state: .firing
        )
    }

    private static func resolved(_ alert: IncomingAlert, at endsAt: Date) -> IncomingAlert {
        IncomingAlert(
            sourceKey: alert.sourceKey,
            severity: alert.severity,
            title: alert.title,
            summary: alert.summary,
            labels: alert.labels,
            annotations: alert.annotations,
            startsAt: alert.startsAt,
            links: alert.links,
            state: .resolved(endsAt: endsAt)
        )
    }
}
