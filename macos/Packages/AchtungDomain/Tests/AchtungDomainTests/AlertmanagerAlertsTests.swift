import AchtungDomain
import Foundation
import Testing

private func alert(
    _ fingerprint: String, _ severity: Severity, _ state: AlertmanagerAlert.State = .active,
    labels: [String: String] = [:]
) -> AlertmanagerAlert {
    AlertmanagerAlert(
        fingerprint: fingerprint, title: "Alert \(fingerprint)", severity: severity,
        summary: nil, startsAt: Fixture.start, labels: labels, annotations: [:], state: state,
        occurrenceID: nil)
}

private func list(_ alerts: [AlertmanagerAlert]) -> AlertmanagerAlerts {
    AlertmanagerAlerts(
        instance: "cdx", status: .reachable(checkedAt: Fixture.start), alerts: alerts)
}

@Test func activeAlertsAreGroupedBySeverityMostSevereFirst() {
    let alerts = list([
        alert("w1", .warning), alert("c1", .critical), alert("u1", .unknown),
        alert("c2", .critical), alert("s1", .critical, .silenced(until: nil)),
    ])

    let groups = alerts.activeBySeverity

    #expect(groups.map(\.severity) == [.critical, .warning, .unknown])
    #expect(groups[0].alerts.map(\.fingerprint) == ["c1", "c2"])
}

@Test func silencedAndInhibitedAlertsAreTheirOwnGroups() {
    let alerts = list([
        alert("a", .warning), alert("s1", .critical, .silenced(until: Fixture.minutes(60))),
        alert("s2", .info, .silenced(until: nil)), alert("i1", .warning, .inhibited),
    ])

    #expect(alerts.silenced.map(\.fingerprint) == ["s1", "s2"])
    #expect(alerts.inhibited.map(\.fingerprint) == ["i1"])
    #expect(alerts.activeBySeverity.flatMap(\.alerts).map(\.fingerprint) == ["a"])
}

@Test func noActiveAlertsMeansNoGroups() {
    #expect(list([alert("s", .critical, .silenced(until: nil))]).activeBySeverity.isEmpty)
    #expect(list([]).activeBySeverity.isEmpty)
}

@Test func keyLabelsArePickedInOrderAndCappedAtThree() {
    let labels = [
        "alertname": "X", "severity": "critical", "cluster": "cdx", "pod": "api-1",
        "namespace": "prod", "job": "api", "team": "core",
    ]

    let picked = alert("a", .critical, labels: labels).keyLabels

    #expect(picked.map(\.name) == ["namespace", "pod", "job"])
    #expect(picked.map(\.value) == ["prod", "api-1", "api"])
    #expect(alert("b", .info, labels: ["team": "core"]).keyLabels.isEmpty)
}

@Test func otherLabelsLeaveOutAlertnameAndSeverity() {
    let other = alert(
        "a", .critical, labels: ["alertname": "X", "severity": "c", "b": "2", "a": "1"]
    )
    .otherLabels
    #expect(other.map(\.name) == ["a", "b"])
}

@Test func theLastReadIsKeptWhenUnreachable() {
    let down = AlertmanagerAlerts(
        instance: "cdx", status: .unreachable(error: "timeout", lastRead: Fixture.start),
        alerts: [])
    let neverRead = AlertmanagerAlerts(
        instance: "lab", status: .unreachable(error: "refused", lastRead: nil), alerts: [])

    #expect(down.checkedAt == Fixture.start)
    #expect(neverRead.checkedAt == nil)
    #expect(list([]).checkedAt == Fixture.start)
}

@Test func silenceAllCoversTheActiveAlertsAndAnyUnsilencedOneCanBePicked() {
    let alerts = list([
        alert("a", .critical), alert("s", .warning, .silenced(until: Fixture.minutes(60))),
        alert("i", .info, .inhibited), alert("u", .unknown),
    ])

    #expect(alerts.silenceableByDefault.map(\.fingerprint) == ["a", "u"])
    #expect(alerts.selectable.map(\.fingerprint) == ["a", "i", "u"])
}

@Test func theSilenceSummarySaysWhatWasSilencedAndWhyTheRestWasnt() {
    let silenced = AlertSilenceResult(fingerprint: "a", outcome: .silenced(until: Fixture.start))
    let gone = AlertSilenceResult(fingerprint: "b", outcome: .failed("No longer in Alertmanager"))
    let unnamed = AlertSilenceResult(fingerprint: "c", outcome: .failed("Refused"))

    let all = AlertSilenceResult.summary(of: [silenced], titles: ["a": "HighErrorRate"])
    let some = AlertSilenceResult.summary(
        of: [silenced, gone, unnamed], titles: ["a": "HighErrorRate", "b": "KubeJobFailed"])

    #expect(all.text == "Silenced 1 alert.")
    #expect(!all.failed)
    #expect(
        some.text
            == "Silenced 1 of 3. Not silenced: KubeJobFailed: No longer in Alertmanager; "
            + "c: Refused.")
    #expect(some.failed)
    #expect(
        AlertSilenceResult.summary(of: [silenced, silenced], titles: [:]).text
            == "Silenced 2 alerts.")
}
