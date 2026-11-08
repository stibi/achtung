import AchtungDomain
import Foundation
import Testing

/// Fixture.start is 2027-01-15 08:00:00 UTC; the window ends 24 h later.
private let window = TimelineWindow(endingAt: Fixture.start.addingTimeInterval(24 * 3600))

private func hoursBeforeEnd(_ hours: Double) -> Date {
    window.end.addingTimeInterval(-hours * 3600)
}

private func occurrence(
    id: Int, started: Double, resolved: Double? = nil, resent: Double? = nil,
    severity: Severity = .warning
) -> Occurrence {
    let startsAt = hoursBeforeEnd(started)
    let state: AlertState = resolved.map { .resolved(endsAt: hoursBeforeEnd($0)) } ?? .firing
    return Occurrence(
        id: id, channel: ChannelID(instance: "onprem", slug: "infra"), source: "alertmanager",
        alert: IncomingAlert(
            sourceKey: "key-\(id)", severity: severity, title: "Alert \(id)", summary: nil,
            labels: [:], annotations: [:], startsAt: startsAt, links: [], state: state),
        firstReceivedAt: startsAt, lastReceivedAt: startsAt,
        lastEventAt: (resolved ?? resent).map(hoursBeforeEnd) ?? startsAt,
        lastEventKind: resolved != nil ? .resolved : resent != nil ? .resent : .fired,
        notificationCount: 1)
}

@Test func positionsRunFromNowAtTheTopToTheStartAtTheBottom() {
    #expect(window.position(of: window.end) == 0)
    #expect(window.position(of: hoursBeforeEnd(6)) == 0.25)
    #expect(window.position(of: window.start) == 1)
    #expect(window.position(of: hoursBeforeEnd(25)) == nil)
    #expect(window.position(of: window.end.addingTimeInterval(1)) == nil)
    #expect(window.clampedPosition(of: hoursBeforeEnd(30)) == 1)
}

@Test func ticksFallOnWholeHoursThatAreAMultiple() throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(identifier: "UTC"))

    let ticks = window.ticks(every: 6, calendar: utc)

    // The window runs from 08:00 to 08:00 the next day.
    #expect(ticks.map { utc.component(.hour, from: $0) } == [6, 0, 18, 12])
    #expect(ticks.first == hoursBeforeEnd(2))
}

@Test func firedAndResolvedMarkersInsideTheWindowOnly() {
    let timeline = Timeline(
        occurrences: [
            occurrence(id: 1, started: 2, resolved: 1),
            occurrence(id: 2, started: 30, resolved: 10),  // fired before the window
            occurrence(id: 3, started: 5),  // still firing
        ],
        readState: ReadState(), window: window)

    #expect(timeline.markers.map(\.id) == ["1-resolved", "1-fired", "3-fired", "2-resolved"])
    let positions: [Double] = [1, 2, 5, 10].map { $0 / 24 }
    #expect(timeline.markers.map(\.position) == positions)
}

@Test func barsMergeFiringTimesPerSeverityLeastSevereFirst() {
    let timeline = Timeline(
        occurrences: [
            occurrence(id: 1, started: 2, resolved: 1),
            occurrence(id: 2, started: 30, resolved: 10),  // started before the window
            occurrence(id: 3, started: 5),  // still firing
            occurrence(id: 4, started: 40, resolved: 30),  // entirely before the window
            occurrence(id: 5, started: 8, resolved: 3, severity: .critical),
        ],
        readState: ReadState(), window: window)

    // Warnings 1 (1–2 h ago), 2 (10–24 h) and 3 (now–5 h): 1 and 3 overlap.
    #expect(timeline.bars.map(\.severity) == [.warning, .warning, .critical])
    #expect(timeline.bars.map(\.top) == [0, 10.0 / 24, 3.0 / 24])
    #expect(timeline.bars.map(\.bottom) == [5.0 / 24, 1, 8.0 / 24])
    #expect(timeline.bars.map(\.isOpen) == [true, false, false])
}

@Test func anAlertFiringSinceBeforeTheWindowHasAFullOpenBarButNoMarkers() {
    // Started 30 h ago, still firing; its last event is outside the window too.
    let timeline = Timeline(
        occurrences: [occurrence(id: 1, started: 30)], readState: ReadState(), window: window)

    #expect(timeline.markers.isEmpty)
    #expect(timeline.bars.map(\.top) == [0])
    #expect(timeline.bars.map(\.bottom) == [1])
}

@Test func anOccurrenceInBothTheFeedAndTheFiringSetCountsOnce() {
    let firing = occurrence(id: 1, started: 2)

    let timeline = Timeline(
        occurrences: [firing, firing], readState: ReadState(), window: window)

    #expect(timeline.markers.count == 1)
}

@Test func unreadMarkersAreMarked() {
    var readState = ReadState()
    let read = occurrence(id: 1, started: 2)
    readState.markRead(read)

    let timeline = Timeline(
        occurrences: [read, occurrence(id: 2, started: 3)], readState: readState, window: window)

    #expect(timeline.markers.map(\.isUnread) == [false, true])
}

@Test func aResentAlertHasAMarkerForItsLastResend() {
    let timeline = Timeline(
        occurrences: [
            occurrence(id: 1, started: 30, resent: 3),  // fired before the window
            occurrence(id: 2, started: 6, resent: 30),  // resent before the window
        ],
        readState: ReadState(), window: window)

    #expect(timeline.markers.map(\.id) == ["1-resent", "2-fired"])
    #expect(timeline.markers[0].position == 3.0 / 24)
}

@Test func nearbyMarkersClusterWithTheirCountNewestSeverityAndUnread() {
    var readState = ReadState()
    let warning = occurrence(id: 1, started: 2.0, severity: .warning)
    readState.markRead(warning)
    let timeline = Timeline(
        occurrences: [
            warning,
            occurrence(id: 2, started: 2.2, severity: .critical),
            occurrence(id: 3, started: 12, severity: .info),
        ],
        readState: readState, window: window)

    let clusters = timeline.clusters(gap: 0.02)  // about 29 minutes

    #expect(clusters.map(\.count) == [2, 1])
    #expect(clusters[0].newest.occurrence.id == 1)
    #expect(clusters[0].severity == .critical)
    #expect(clusters[0].hasUnread)
    // Drawn at its newest marker.
    #expect(clusters[0].position == 2.0 / 24)
    #expect(clusters[1].severity == .info)
}

@Test func anAlertThatFiredAndResolvedCloseTogetherCountsAsOneAlert() {
    let timeline = Timeline(
        occurrences: [
            occurrence(id: 1, started: 2.0, resolved: 1.9), occurrence(id: 2, started: 2.1),
        ],
        readState: ReadState(), window: window)

    let clusters = timeline.clusters(gap: 0.02)

    #expect(clusters.map(\.count) == [3])
    #expect(clusters.map(\.alertCount) == [2])
}

@Test func aLongBurstSplitsIntoSeveralClusters() {
    // One marker every 20 minutes for 2 hours.
    let occurrences = (0..<7).map { occurrence(id: $0, started: 1 + Double($0) / 3) }
    let timeline = Timeline(occurrences: occurrences, readState: ReadState(), window: window)

    let clusters = timeline.clusters(gap: 0.02)

    #expect(clusters.map(\.count) == [2, 2, 2, 1])
    #expect(timeline.clusters(gap: 0.001).count == 7)
}

@Test func drawnClustersAreNeverCloserThanTheGap() {
    // Markers every 12 minutes for 4 hours, clustered with a 15-minute gap.
    let occurrences = (0..<20).map { occurrence(id: $0, started: 1 + Double($0) / 5) }
    let gap = 0.25 / 24
    let positions = Timeline(occurrences: occurrences, readState: ReadState(), window: window)
        .clusters(gap: gap).map(\.position)

    #expect(positions.count > 1)
    #expect(zip(positions, positions.dropFirst()).allSatisfy { $1 - $0 >= gap })
}
