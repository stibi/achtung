import AchtungDomain
import Foundation
import Testing

@Test func anOccurrenceIsUnreadUntilOpened() {
    var state = ReadState()
    let occurrence = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1))
    #expect(!state.isRead(occurrence))

    state.markRead(occurrence)

    #expect(state.isRead(occurrence))
    #expect(!state.isRead(Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(1))))
}

@Test func anEventAfterReadingMakesItUnreadAgain() {
    var state = ReadState()
    state.markRead(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1)))

    #expect(!state.isRead(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(5))))
}

@Test func readingAnOlderVersionDoesNotForgetANewerRead() {
    var state = ReadState()
    state.markRead(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(5)))
    state.markRead(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1)))

    #expect(state.isRead(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(5))))
}

@Test func nothingIsNewBeforeTheFirstVisit() {
    let state = ReadState()
    #expect(!state.isNew(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1))))
    #expect(!state.hasNews(Fixture.channel("infra", firing: 1, lastEventAt: Fixture.minutes(1))))
}

@Test func whatChangedAfterTheUserLeftIsNew() {
    var state = ReadState()
    state.markSeen(upTo: Fixture.minutes(2))

    #expect(state.isNew(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(3))))
    #expect(!state.isNew(Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(2))))
    #expect(state.hasNews(Fixture.channel("infra", firing: 0, lastEventAt: Fixture.minutes(3))))
    #expect(!state.hasNews(Fixture.channel("apps", firing: 0, lastEventAt: Fixture.minutes(1))))
    #expect(!state.hasNews(Fixture.channel("empty", firing: 0, lastEventAt: nil)))
}

@Test func survivesARoundTripThroughJSON() throws {
    var state = ReadState()
    state.markRead(Fixture.occurrence(id: 7, lastEventAt: Fixture.minutes(1)))
    state.markSeen(upTo: Fixture.minutes(2))
    state.markVisited(Fixture.channel("infra", firing: 1, lastEventAt: Fixture.minutes(3)))

    let decoded = try JSONDecoder().decode(ReadState.self, from: JSONEncoder().encode(state))

    #expect(decoded == state)
}

@Test func theSeenMarkerNeverMovesBack() {
    var state = ReadState()
    state.markSeen(upTo: Fixture.minutes(5))
    state.markSeen(upTo: Fixture.minutes(2))

    #expect(state.seenUntil == Fixture.minutes(5))
}

@Test func visitingAChannelClearsItsNewsUntilItChangesAgain() {
    var state = ReadState()
    state.markSeen(upTo: Fixture.minutes(1))
    let changed = Fixture.channel("infra", firing: 1, lastEventAt: Fixture.minutes(3))
    #expect(state.hasNews(changed))

    state.markVisited(changed)

    #expect(!state.hasNews(changed))
    #expect(state.hasNews(Fixture.channel("infra", firing: 1, lastEventAt: Fixture.minutes(4))))
    #expect(state.hasNews(Fixture.channel("apps", firing: 0, lastEventAt: Fixture.minutes(3))))
}

@Test func channelsWithTheSameNameInTwoInstancesAreVisitedSeparately() {
    var state = ReadState()
    state.markSeen(upTo: Fixture.minutes(1))
    let onprem = Fixture.channel(
        "devops", instance: "onprem", firing: 1, lastEventAt: Fixture.minutes(3))
    let cloud = Fixture.channel(
        "devops", instance: "cloud", firing: 1, lastEventAt: Fixture.minutes(3))

    state.markVisited(onprem)

    #expect(!state.hasNews(onprem))
    #expect(state.hasNews(cloud))
}

@Test func readsTheFormatFromBeforeInstancesAndKeepsReadMarks() throws {
    // Channel visits were keyed by name alone; dates are seconds since 2001 (JSONEncoder).
    let stored = Data(
        """
        {"readUpTo": {"7": 820000000}, "channelSeenUpTo": {"devops": 820000500},
         "seenUntil": 820000900}
        """.utf8)

    let state = try JSONDecoder().decode(ReadState.self, from: stored)

    let read = Fixture.occurrence(
        id: 7, lastEventAt: Date(timeIntervalSinceReferenceDate: 820_000_000))
    #expect(state.isRead(read))
    #expect(state.seenUntil == Date(timeIntervalSinceReferenceDate: 820_000_900))
    // The dropped visit falls back to seenUntil.
    let devops = Fixture.channel(
        "devops", firing: 0, lastEventAt: Date(timeIntervalSinceReferenceDate: 820_000_600))
    #expect(!state.hasNews(devops))
}

@Test func malformedChannelVisitsAreAnErrorNotTheOldFormat() {
    // Neither the current format (ChannelID keys) nor the old one (names as keys).
    let stored = Data(#"{"readUpTo": {}, "channelSeenUpTo": [1, 2]}"#.utf8)

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ReadState.self, from: stored)
    }
}

@Test func everythingAtOrBeforeTheBaselineIsRead() {
    var state = ReadState()
    state.setBaselineIfMissing(Fixture.minutes(5))

    #expect(state.isRead(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(4))))
    #expect(state.isRead(Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(5))))
    // A fire, resolve or reopen after the baseline makes it unread, as before.
    #expect(!state.isRead(Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(6))))
}

@Test func theBaselineIsSetOnce() {
    var state = ReadState()
    state.setBaselineIfMissing(Fixture.minutes(5))
    state.setBaselineIfMissing(Fixture.minutes(9))

    #expect(state.baseline == Fixture.minutes(5))
}

@Test func aStoredStateWithoutABaselineGetsOneOnFirstUse() throws {
    var state = ReadState()
    state.markRead(Fixture.occurrence(id: 7, lastEventAt: Fixture.minutes(8)))
    var stored =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
    stored?.removeValue(forKey: "baseline")
    let migrated = try JSONDecoder().decode(
        ReadState.self, from: JSONSerialization.data(withJSONObject: try #require(stored)))
    #expect(migrated.baseline == nil)

    var updated = migrated
    updated.setBaselineIfMissing(Fixture.minutes(5))

    #expect(updated.baseline == Fixture.minutes(5))
    #expect(updated.isRead(Fixture.occurrence(id: 7, lastEventAt: Fixture.minutes(8))))
    #expect(updated.isRead(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(3))))
}

@Test func firstUnreadIsTheNewestChangeNotYetRead() {
    var state = ReadState()
    let list = [3, 2, 1].map {
        Fixture.occurrence(id: $0, lastEventAt: Fixture.minutes(Double($0)))
    }
    state.markRead(list[0])

    #expect(state.firstUnread(in: list)?.id == 2)

    state.markRead(list[1])
    state.markRead(list[2])
    #expect(state.firstUnread(in: list) == nil)
}

// Moving the baseline forward. Minutes are relative to Fixture.start.

private func baselineAt(_ minutes: Double) -> ReadState {
    var state = ReadState()
    state.setBaselineIfMissing(Fixture.minutes(minutes))
    return state
}

@Test func withNothingUnreadTheBaselineMovesToTheNewestChangeMinusTheLag() {
    var state = baselineAt(0)
    let feed = [
        Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(10)),
        Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(5)),
    ]
    for occurrence in feed {
        state.markRead(occurrence)
    }

    let moved = state.advanceBaseline(over: feed, hasOlder: false)
    #expect(moved)

    #expect(state.baseline == Fixture.minutes(9))
    #expect(feed.allSatisfy { state.isRead($0) })
    // The mark at minute 5 is gone (the baseline covers it); the one at 10 stays.
    var expected = baselineAt(9)
    expected.markRead(feed[0])
    #expect(state == expected)
}

@Test func theBaselineStopsJustBeforeTheOldestUnread() throws {
    var state = baselineAt(0)
    let oldUnread = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(3))
    let read = Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(8))
    state.markRead(read)

    state.advanceBaseline(over: [read, oldUnread], hasOlder: false)

    #expect(try #require(state.baseline) < Fixture.minutes(3))
    #expect(try #require(state.baseline) > Fixture.minutes(2.99))
    #expect(!state.isRead(oldUnread))
    #expect(state.isRead(read))
}

@Test func aLoadThatStoppedAtTheCapLeavesTheBaselineAlone() {
    var state = baselineAt(0)
    // Older pages remain and the oldest loaded change is still after the baseline.
    let feed = [Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(10))]
    state.markRead(feed[0])

    let moved = state.advanceBaseline(over: feed, hasOlder: true)
    #expect(!moved)

    #expect(state.baseline == Fixture.minutes(0))
}

@Test func aFeedThatReachesTheBaselineMovesItEvenWithOlderPagesLeft() {
    var state = baselineAt(0)
    let feed = [
        Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(10)),
        Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(0)),
    ]
    state.markRead(feed[0])

    let moved = state.advanceBaseline(over: feed, hasOlder: true)
    #expect(moved)

    #expect(state.baseline == Fixture.minutes(9))
}

@Test func theBaselineNeverMovesBack() {
    var state = baselineAt(20)
    let feed = [Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(10))]

    let moved = state.advanceBaseline(over: feed, hasOlder: false)
    #expect(!moved)

    #expect(state.baseline == Fixture.minutes(20))
}

@Test func anOccurrenceThatChangesAfterTheBaselineMovedIsUnreadAgain() {
    var state = baselineAt(0)
    let old = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(2))
    let newest = Fixture.occurrence(id: 9, lastEventAt: Fixture.minutes(10))
    state.markRead(old)
    state.markRead(newest)

    state.advanceBaseline(over: [newest, old], hasOlder: false)
    #expect(state.baseline == Fixture.minutes(9))

    // The old occurrence resolves later: its read mark was pruned, and it's above the
    // baseline now, so it comes back as unread.
    #expect(!state.isRead(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(12))))
    #expect(state.isRead(old))
}

@Test func pruningReadMarksNeverChangesWhatIsRead() throws {
    var state = baselineAt(0)
    let marks = (1...6).map { Fixture.occurrence(id: $0, lastEventAt: Fixture.minutes(Double($0))) }
    for occurrence in marks {
        state.markRead(occurrence)
    }
    let unread = Fixture.occurrence(id: 7, lastEventAt: Fixture.minutes(4.5))
    // Each occurrence as it is now, and as it would be after changing again.
    let probes =
        marks
        + marks.map {
            Fixture.occurrence(id: $0.id, lastEventAt: $0.lastEventAt.addingTimeInterval(600))
        } + [unread]
    let before = probes.map { state.isRead($0) }

    state.advanceBaseline(over: marks + [unread], hasOlder: false)

    #expect(try #require(state.baseline) < Fixture.minutes(4.5))
    #expect(probes.map { state.isRead($0) } == before)
}
