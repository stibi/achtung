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
