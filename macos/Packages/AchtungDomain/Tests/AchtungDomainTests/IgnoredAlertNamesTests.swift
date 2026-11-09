import AchtungDomain
import Foundation
import Testing

@Test func anAddedNameIsTrimmedAndSorted() {
    #expect(
        IgnoredAlertNames.adding("  KubeJobFailed\n", to: ["InfoInhibitor", "Watchdog"])
            == ["InfoInhibitor", "KubeJobFailed", "Watchdog"])
}

@Test func anEmptyOrRepeatedNameAddsNothing() {
    #expect(IgnoredAlertNames.adding("   ", to: ["Watchdog"]) == nil)
    #expect(IgnoredAlertNames.adding(" Watchdog ", to: ["Watchdog"]) == nil)
}

@Test func namesMatchCaseSensitively() {
    #expect(IgnoredAlertNames.adding("watchdog", to: ["Watchdog"]) == ["Watchdog", "watchdog"])
}

@Test func anAlertsAlertnameIsItsLabel() {
    let alert = AlertmanagerAlert(
        fingerprint: "f", title: "f", severity: .unknown, summary: nil, startsAt: Fixture.start,
        labels: ["alertname": "Watchdog"], annotations: [:], state: .active, occurrenceID: nil)
    #expect(alert.alertname == "Watchdog")
}
