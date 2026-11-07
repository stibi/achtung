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
    #expect(!state.hasNews(Channel(slug: "infra", firing: 1, lastEventAt: Fixture.minutes(1))))
}

@Test func whatChangedAfterTheUserLeftIsNew() {
    var state = ReadState()
    state.markSeen(upTo: Fixture.minutes(2))

    #expect(state.isNew(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(3))))
    #expect(!state.isNew(Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(2))))
    #expect(state.hasNews(Channel(slug: "infra", firing: 0, lastEventAt: Fixture.minutes(3))))
    #expect(!state.hasNews(Channel(slug: "apps", firing: 0, lastEventAt: Fixture.minutes(1))))
    #expect(!state.hasNews(Channel(slug: "empty", firing: 0, lastEventAt: nil)))
}

@Test func survivesARoundTripThroughJSON() throws {
    var state = ReadState()
    state.markRead(Fixture.occurrence(id: 7, lastEventAt: Fixture.minutes(1)))
    state.markSeen(upTo: Fixture.minutes(2))
    state.markVisited(Channel(slug: "infra", firing: 1, lastEventAt: Fixture.minutes(3)))

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
    let changed = Channel(slug: "infra", firing: 1, lastEventAt: Fixture.minutes(3))
    #expect(state.hasNews(changed))

    state.markVisited(changed)

    #expect(!state.hasNews(changed))
    #expect(state.hasNews(Channel(slug: "infra", firing: 1, lastEventAt: Fixture.minutes(4))))
    #expect(state.hasNews(Channel(slug: "apps", firing: 0, lastEventAt: Fixture.minutes(3))))
}
