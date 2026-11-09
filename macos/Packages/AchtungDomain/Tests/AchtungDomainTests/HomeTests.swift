import AchtungDomain
import Foundation
import Testing

private func counts(
    critical: Int = 0, warning: Int = 0, info: Int = 0, other: Int = 0
) -> OpenAlertCounts {
    OpenAlertCounts(
        total: critical + warning + info + other, critical: critical, warning: warning,
        info: info, other: other)
}

@Test(arguments: [
    (counts(), OpenAlertCounts.Emphasis.allQuiet),
    (counts(critical: 1, warning: 5, info: 2), .critical),
    (counts(warning: 3, other: 1), .warning),
    (counts(info: 2, other: 1), .neutral),
    (counts(other: 4), .neutral),
])
func theTotalTakesTheWorstSeverityPresent(
    counts: OpenAlertCounts, emphasis: OpenAlertCounts.Emphasis
) {
    #expect(counts.emphasis == emphasis)
}

@Test func theBreakdownLeavesOutZeros() {
    let mixed = counts(critical: 3, warning: 8, info: 2, other: 2)
    #expect(mixed.breakdown == "3 critical · 8 warning · 2 info · 2 other")
    #expect(counts(warning: 1, other: 4).breakdown == "1 warning · 4 other")
    #expect(counts().breakdown == nil)
    #expect(
        counts(critical: 1, other: 2).bySeverity.map(\.severity) == [.critical, .unknown])
}

@Test func silencedAndInhibitedLeaveOutZeros() {
    func read(silenced: Int, inhibited: Int) -> AlertmanagerOverview.Read {
        AlertmanagerOverview.Read(
            checkedAt: Fixture.start, open: counts(), silenced: silenced, inhibited: inhibited,
            watchdogFires: true,
            delivery: Delivery(missingInAchtung: [], staleInAchtung: []))
    }
    #expect(read(silenced: 4, inhibited: 1).quieted == "4 silenced · 1 inhibited")
    #expect(read(silenced: 0, inhibited: 2).quieted == "2 inhibited")
    #expect(read(silenced: 0, inhibited: 0).quieted == nil)
}

@Test func deliverySummarisesWhatIsMissingAndStale() {
    let missing = MissingAlert(
        fingerprint: "f1", title: "DiskFull", severity: .critical, startsAt: Fixture.start)
    let stale = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1))

    let broken = Delivery(missingInAchtung: [missing, missing], staleInAchtung: [stale])
    let healthy = Delivery(missingInAchtung: [], staleInAchtung: [])

    #expect(broken.summary == "2 missing · 1 stale")
    #expect(Delivery(missingInAchtung: [], staleInAchtung: [stale]).summary == "1 stale")
    #expect(healthy.summary == nil)
}

private let durations: [(TimeInterval, String)] = [
    (0, "under a minute"), (59, "under a minute"), (60, "1m"), (45 * 60, "45m"),
    (2 * 3600, "2h"), (2 * 3600 + 10 * 60, "2h 10m"), (24 * 3600, "1d"),
    (3 * 86400 + 4 * 3600 + 59 * 60, "3d 4h"), (-30, "under a minute"),
]

@Test(arguments: durations)
func shortDurationsShowTheTwoLargestUnits(interval: TimeInterval, text: String) {
    #expect(shortDuration(interval) == text)
}

private func matcher(
    _ name: String, _ value: String, regex: Bool = false, equal: Bool = true
) -> Silence.Matcher {
    Silence.Matcher(name: name, value: value, isRegex: regex, isEqual: equal)
}

private func silence(_ matchers: [Silence.Matcher]) -> Silence {
    Silence(
        instance: "cdx", silenceID: "s1", endsAt: Fixture.minutes(60),
        createdBy: "ops", comment: "", matchers: matchers)
}

@Test func aSilenceSummaryLeadsWithTheAlertname() {
    let summary = silence([
        matcher("namespace", "prod"), matcher("alertname", "HighErrorRate"),
        matcher("pod", "api-.*", regex: true), matcher("env", "dev", equal: false),
        matcher("team", "core"),
    ]).summary

    #expect(summary == "HighErrorRate · namespace=prod, pod=~api-.* and 2 more")
    #expect(silence([matcher("alertname", "Disk")]).summary == "Disk")
    #expect(silence([matcher("env", "dev", regex: true, equal: false)]).summary == "env!~dev")
    #expect(silence([]).summary == "Everything")
}

@Test func aRegexAlertnameIsAnotherMatcher() {
    let summary = silence([matcher("alertname", "Kube.*", regex: true)]).summary
    #expect(summary == "alertname=~Kube.*")
}
