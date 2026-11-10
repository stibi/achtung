import AchtungDomain
import Foundation
import Testing

private func occurrence(
    _ id: Int, at minutes: Double, kind: OccurrenceEvent.Kind = .fired,
    severity: Severity = .critical, name: String? = nil, instance: String = "onprem",
    resolved: Bool = false, silencedUntil: Date? = nil
) -> Occurrence {
    let title = name ?? "Alert\(id)"
    return Occurrence(
        id: id, channel: ChannelID(instance: instance, slug: "devops"), source: "alertmanager",
        alert: IncomingAlert(
            sourceKey: "k\(id)", severity: severity, title: title, summary: nil,
            labels: ["alertname": title], annotations: [:], startsAt: Fixture.start, links: [],
            state: resolved ? .resolved(endsAt: Fixture.minutes(minutes)) : .firing),
        firstReceivedAt: Fixture.start, lastReceivedAt: Fixture.minutes(minutes),
        lastEventAt: Fixture.minutes(minutes), lastEventKind: resolved ? .resolved : kind,
        notificationCount: 1, silencedUntil: silencedUntil)
}

private let critical = NotificationRules(severities: [.critical], ignoredNames: [])

private func notifying(
    _ feed: [Occurrence], rules: NotificationRules = critical,
    ledger: NotificationLedger = NotificationLedger(), readState: ReadState = ReadState(),
    baseline: Date = Fixture.start
) -> [Int] {
    ledger.notifying(
        in: feed, after: baseline, rules: rules, readState: readState, now: Fixture.minutes(30)
    )
    .map(\.id)
}

@Test func theFirstRefreshOnlySetsTheBaseline() {
    let feed = [occurrence(1, at: 5), occurrence(2, at: 9)]
    let baseline = AlertNotificationPlan.baseline(for: feed)

    #expect(baseline == Fixture.minutes(9))
    #expect(notifying(feed, baseline: baseline).isEmpty)
    #expect(notifying(feed + [occurrence(3, at: 12)], baseline: baseline) == [3])
    #expect(AlertNotificationPlan.baseline(for: []) == .distantPast)
}

@Test func newReopenedAndResentFiringsNotifyNewestFirst() {
    let feed = [
        occurrence(1, at: 5), occurrence(2, at: 9, kind: .resent),
        occurrence(3, at: 7, kind: .reopened), occurrence(4, at: 8, resolved: true),
    ]

    #expect(notifying(feed) == [2, 3, 1])
}

@Test func eachEventNotifiesOnce() {
    var ledger = NotificationLedger()
    let fired = occurrence(1, at: 5)
    ledger.record([fired])

    #expect(notifying([fired], ledger: ledger).isEmpty)
    // The same occurrence resent later is a new event.
    #expect(notifying([occurrence(1, at: 65, kind: .resent)], ledger: ledger) == [1])
}

@Test func theLedgerForgetsOldEvents() {
    var ledger = NotificationLedger()
    ledger.record([occurrence(1, at: 5), occurrence(2, at: 50)])
    ledger.forget(before: Fixture.minutes(10))

    #expect(ledger.notified.keys.sorted() == [2])
}

@Test func onlyTheChosenSeveritiesNotify() {
    let feed = [occurrence(1, at: 5), occurrence(2, at: 6, severity: .warning)]

    #expect(notifying(feed) == [1])
    #expect(
        notifying(
            feed, rules: NotificationRules(severities: [.critical, .warning], ignoredNames: []))
            == [2, 1])
}

@Test func ignoredSilencedAndReadAlertsDontNotify() {
    let read = occurrence(3, at: 7)
    var readState = ReadState()
    readState.markRead(read)
    let feed = [
        occurrence(1, at: 5, name: "Watchdog"),
        occurrence(2, at: 6, silencedUntil: Fixture.minutes(90)),
        read,
        occurrence(4, at: 8, silencedUntil: Fixture.minutes(20)),  // The silence has ended.
    ]

    #expect(
        notifying(
            feed, rules: NotificationRules(severities: [.critical], ignoredNames: ["Watchdog"]),
            readState: readState) == [4])
}

@Test func moreThanThreeBecomeOneSummary() {
    let three = (1...3).map { occurrence($0, at: Double($0)) }
    let four = three + [occurrence(4, at: 4, instance: "cdx")]

    #expect(AlertNotificationPlan.delivery(of: three) == .each(three))
    #expect(AlertNotificationPlan.delivery(of: four) == .summary(four))
}

@Test func theSummarySaysHowManyAndWhere() {
    let onprem = (1...5).map { occurrence($0, at: Double($0)) }
    let mixed = [occurrence(6, at: 6, severity: .warning, instance: "cdx")] + onprem

    #expect(AlertNotificationPlan.summaryTitle(of: onprem) == "5 critical alerts on onprem")
    #expect(AlertNotificationPlan.summaryTitle(of: mixed) == "6 alerts on 2 instances")
    #expect(
        AlertNotificationPlan.summaryBody(of: onprem) == "Alert1, Alert2, Alert3 and 2 more")
    #expect(AlertNotificationPlan.summaryBody(of: Array(onprem.prefix(2))) == "Alert1, Alert2")
}

private func refresh(
    _ state: inout AlertNotificationState, _ feed: [Occurrence], isOn: Bool = true,
    rules: NotificationRules = critical
) -> [Int] {
    state.refreshed(
        feed: feed, isOn: isOn, rules: rules, readState: ReadState(), now: Fixture.minutes(30)
    )
    .map(\.id)
}

@Test func theFirstRefreshAnnouncesNothingAndLaterOnesAnnounceOnce() {
    var state = AlertNotificationState()
    let old = occurrence(1, at: 5)

    #expect(refresh(&state, [old]).isEmpty)
    #expect(state.baseline == Fixture.minutes(5))
    let new = occurrence(2, at: 9)
    #expect(refresh(&state, [new, old]) == [2])
    #expect(refresh(&state, [new, old]).isEmpty)
}

@Test func whatHappensWhileOffIsNotAnnouncedLater() {
    var state = AlertNotificationState()
    _ = refresh(&state, [occurrence(1, at: 5)])
    let whileOff = occurrence(2, at: 9)

    #expect(refresh(&state, [whileOff], isOn: false).isEmpty)
    #expect(refresh(&state, [whileOff]).isEmpty)
    #expect(refresh(&state, [occurrence(3, at: 12), whileOff]) == [3])
}

@Test func aNewlyPickedSeverityStartsFromNow() {
    var state = AlertNotificationState()
    let warning = occurrence(1, at: 5, severity: .warning)
    let both = NotificationRules(severities: [.critical, .warning], ignoredNames: [])
    _ = refresh(&state, [])
    _ = refresh(&state, [warning])

    // The warning fired before warnings were picked: not announced. A critical alert new
    // in the same refresh still is.
    let critical = occurrence(3, at: 7)
    #expect(refresh(&state, [critical, warning], rules: both) == [3])
    #expect(
        refresh(&state, [occurrence(2, at: 9, severity: .warning), warning], rules: both) == [2])
}
