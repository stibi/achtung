import AchtungDomain
import Foundation
import Testing

private func alert(
    labels: [String: String] = [:], annotations: [String: String] = [:],
    links: [AlertLink] = []
) -> IncomingAlert {
    IncomingAlert(
        sourceKey: "k", severity: .warning, title: "T", summary: nil, labels: labels,
        annotations: annotations, startsAt: Fixture.start, links: links, state: .firing)
}

@Test func labelsThatSayWhereComeFirstThenTheRestByName() {
    let labels = [
        "team": "core", "pod": "api-1", "alertname": "X", "namespace": "prod",
        "severity": "warning", "env": "eu",
    ]

    #expect(
        alert(labels: labels).orderedLabels.map(\.name)
            == ["alertname", "severity", "namespace", "pod", "env", "team"])
}

@Test func urlAnnotationsAreLinksUnlessTheAlertLinksThemAlready() {
    let runbook = URL(string: "https://runbooks.example.com/x")!
    let annotated = alert(
        annotations: [
            "runbook_url": runbook.absoluteString,
            "dashboard_url": " https://grafana.example.com/d/x ",
            "summary": "https://looks.like/a-url",
            "note": "see https://example.com for more",
            "ftp": "ftp://files.example.com/x",
        ],
        links: [AlertLink(kind: .runbook, url: runbook)])

    // The summary is prose, even when it's only a URL.
    #expect(annotated.linkAnnotations.map(\.name) == ["dashboard_url"])
}

@Test func theSummaryAndDescriptionLeadTheAnnotations() {
    let annotated = alert(
        annotations: ["owner": "o", "description": "d", "summary": "s", "impact": "i"])

    #expect(
        annotated.orderedAnnotations.map(\.name) == ["summary", "description", "impact", "owner"])
    #expect(annotated.alertDescription == "d")
    #expect(alert(annotations: ["description": ""]).alertDescription == nil)
}

@Test(arguments: [
    ("runbook_url", "Runbook"), ("generatorURL", "Generator"), ("dashboard", "Dashboard"),
    ("grafana-dashboard", "Grafana dashboard"), ("url", "url"),
])
func linkTitlesAreTheNameInWords(name: String, title: String) {
    #expect(linkTitle(forAnnotation: name) == title)
}
