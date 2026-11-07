import AchtungDomain
import Testing

@Test func keepsTheServersOrderNewestChangeFirstThenId() {
    var list = OccurrenceList()
    list.merge([
        Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1)),
        Fixture.occurrence(id: 3, lastEventAt: Fixture.minutes(2)),
        Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(2)),
    ])

    #expect(list.occurrences.map(\.id) == [3, 2, 1])
    #expect(list.refreshSince == Fixture.minutes(1))
}

@Test func aChangedOccurrenceReplacesTheOldOneAndMovesUp() {
    var list = OccurrenceList()
    list.merge([
        Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1)),
        Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(2)),
    ])

    list.merge([Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(9))])

    #expect(list.occurrences.map(\.id) == [1, 2])
    #expect(list.occurrences.map(\.lastEventAt) == [Fixture.minutes(9), Fixture.minutes(2)])
}

@Test func anEmptyListHasNothingToRefreshFrom() {
    #expect(OccurrenceList().refreshSince == nil)
}
