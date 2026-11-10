import AchtungDomain
import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26T07:33:20Z

private func occurrence(
    _ alert: IncomingAlert, lastEventKind: OccurrenceEvent.Kind = .fired,
    silencedUntil: Date? = nil
) -> Occurrence {
    Occurrence(
        id: 42, channel: ChannelID(instance: "eu-prod", slug: "payments"),
        source: "alertmanager", alert: alert, firstReceivedAt: start,
        lastReceivedAt: start.addingTimeInterval(3600), lastEventAt: start.addingTimeInterval(3600),
        lastEventKind: lastEventKind, notificationCount: 13, silencedUntil: silencedUntil)
}

private func alert(
    summary: String? = "7% of card authorisations failed.",
    labels: [String: String] = [:], annotations: [String: String] = [:],
    links: [AlertLink] = [], state: AlertState = .firing
) -> IncomingAlert {
    IncomingAlert(
        sourceKey: "3f9c2e1a", severity: .critical, title: "CardAuthorisationsFailing",
        summary: summary, labels: labels, annotations: annotations, startsAt: start,
        links: links, state: state)
}

private let manyLabels = [
    "alertname": "CardAuthorisationsFailing", "severity": "critical", "cluster": "eu-prod-1",
    "namespace": "payments", "pod": "payments-api-7f9c4d-x2kq", "job": "payments-api",
    "team": "payments", "prometheus": "monitoring/k8s", "endpoint": "http",
    "container": "api", "instance": "10.0.3.17:8080", "service": "payments-api",
]

private let expectedReport = """
    # CardAuthorisationsFailing

    - State: firing, resent
    - Severity: critical
    - Source: alertmanager, instance `eu-prod`, channel `#payments`
    - Started: 2026-10-26T07:33:20Z
    - Last event: resent at 2026-10-26T08:33:20Z
    - Received: first 2026-10-26T07:33:20Z, last 2026-10-26T08:33:20Z, 13 notifications
    - Source key (fingerprint): `3f9c2e1a`
    - Achtung occurrence: 42

    ## Summary

    7% of card authorisations failed.

    ## Description

    Failures started after the 07:30 deploy.
    Check the PSP status page.

    ## Links

    - Runbook: https://runbooks.example.com/card-auth
    - Dashboard (`dashboard_url`): https://grafana.example.com/d/payments

    ## Annotations

    - `dashboard_url`: https://grafana.example.com/d/payments
    - `owner`: team-payments
    - `runbook_url`: https://runbooks.example.com/card-auth

    ## Labels

    ```
    alertname=CardAuthorisationsFailing
    cluster=eu-prod-1
    container=api
    endpoint=http
    instance=10.0.3.17:8080
    job=payments-api
    namespace=payments
    pod=payments-api-7f9c4d-x2kq
    prometheus=monitoring/k8s
    service=payments-api
    severity=critical
    team=payments
    ```

    ## History

    - 2026-10-26T07:33:20Z fired
    - 2026-10-26T08:33:20Z resent

    """

@Test func theReportHasTheFactsTheProseTheAnnotationsAndTheLabels() {
    let firing = alert(
        labels: manyLabels,
        annotations: [
            "summary": "7% of card authorisations failed.",
            "description": "Failures started after the 07:30 deploy.\nCheck the PSP status page.",
            "runbook_url": "https://runbooks.example.com/card-auth",
            "dashboard_url": "https://grafana.example.com/d/payments",
            "owner": "team-payments",
        ],
        links: [
            AlertLink(kind: .runbook, url: URL(string: "https://runbooks.example.com/card-auth")!)
        ])
    let events = [
        OccurrenceEvent(id: 1, kind: .fired, recordedAt: start),
        OccurrenceEvent(id: 2, kind: .resent, recordedAt: start.addingTimeInterval(3600)),
    ]

    let report = AgentReport.markdown(
        for: occurrence(firing, lastEventKind: .resent), events: events,
        now: start.addingTimeInterval(7200))

    #expect(report == expectedReport)
}

@Test func aBareAlertLeavesOutTheEmptySections() {
    let resolved = alert(summary: nil, state: .resolved(endsAt: start.addingTimeInterval(600)))

    let report = AgentReport.markdown(for: occurrence(resolved), now: start)

    #expect(report.contains("- State: resolved\n"))
    #expect(report.contains("- Resolved: 2026-10-26T07:43:20Z\n"))
    for section in ["Summary", "Description", "Links", "Annotations", "Labels", "History"] {
        #expect(!report.contains("## \(section)"))
    }
}

@Test func aMultilineAnnotationStaysInsideItsListItem() {
    let report = AgentReport.markdown(
        for: occurrence(alert(annotations: ["query": "sum(rate(x[5m]))\n  > 0.05"])), now: start)

    #expect(report.contains("- `query`: sum(rate(x[5m]))\n    > 0.05\n"))
}

@Test func aSilenceShowsOnlyWhileItLasts() {
    let silenced = occurrence(alert(), silencedUntil: start.addingTimeInterval(3600))

    #expect(
        AgentReport.markdown(for: silenced, now: start)
            .contains("- State: firing, silenced until 2026-10-26T08:33:20Z\n"))
    #expect(
        AgentReport.markdown(for: silenced, now: start.addingTimeInterval(7200))
            .contains("- State: firing\n"))
}

@Test func aDescriptionThatRepeatsTheSummaryIsLeftOut() {
    let same = alert(annotations: ["description": "7% of card authorisations failed."])

    #expect(!AgentReport.markdown(for: occurrence(same), now: start).contains("## Description"))
}

@Test func aLabelWithBackticksCantCloseTheCodeBlock() {
    let report = AgentReport.markdown(
        for: occurrence(alert(labels: ["query": "x```y"])), now: start)

    #expect(report.contains("## Labels\n\n````\nquery=x```y\n````"))
}

@Test func theHistorySaysWhenAchtungResolvedAnAlertItself() {
    let resolved = alert(state: .resolved(endsAt: start.addingTimeInterval(600)))
    let events = [
        OccurrenceEvent(id: 1, kind: .fired, recordedAt: start),
        OccurrenceEvent(
            id: 2, kind: .resolved, cause: .vanished, recordedAt: start.addingTimeInterval(600)),
    ]

    let report = AgentReport.markdown(for: occurrence(resolved), events: events, now: start)

    #expect(
        report.contains(
            "- 2026-10-26T07:33:20Z fired\n- 2026-10-26T07:43:20Z resolved (gone from "
                + "Alertmanager: Achtung resolved it itself, Alertmanager never sent the "
                + "resolve)\n"))
}
