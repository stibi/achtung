import AchtungDomain
import Foundation
import Testing

@Test func aChannelHidesReadAlertsUntilTurnedOffForItAlone() throws {
    var state = ReadState()
    let infra = ChannelID(instance: "onprem", slug: "infra")
    let cloudInfra = ChannelID(instance: "cloud", slug: "infra")
    #expect(state.hidesRead(in: .channel(infra)))

    state.setHidesRead(false, in: .channel(infra))

    #expect(!state.hidesRead(in: .channel(infra)))
    #expect(state.hidesRead(in: .channel(cloudInfra)))
    let decoded = try JSONDecoder().decode(ReadState.self, from: JSONEncoder().encode(state))
    #expect(!decoded.hidesRead(in: .channel(infra)))
    state.setHidesRead(true, in: .channel(infra))
    #expect(state.hidesRead(in: .channel(infra)))
}

@Test func aStoredStateFromBeforeTheFilterHidesReadEverywhere() throws {
    let stored = Data(#"{"readUpTo": {}, "channelSeenUpTo": []}"#.utf8)
    let state = try JSONDecoder().decode(ReadState.self, from: stored)
    #expect(state.hidesRead(in: .channel(ChannelID(instance: "onprem", slug: "infra"))))
}

@Test func hidingReadShowsOnlyUnreadOccurrences() {
    var state = ReadState()
    let read = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1))
    let unread = Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(2))
    state.markRead(read)

    let shown = state.shown(
        own: [unread, read], feed: [], in: .channel(read.channel), keeping: nil)

    #expect(shown.map(\.id) == [2])
}

@Test func theSelectedOccurrenceStaysShownOnceRead() {
    var state = ReadState()
    let selected = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(2))
    let other = Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(1))
    state.markRead(selected)
    state.markRead(other)

    #expect(
        state.shown(own: [selected, other], feed: [], in: .channel(selected.channel), keeping: 1)
            .map(\.id)
            == [1])
    #expect(
        state.shown(own: [selected, other], feed: [], in: .channel(selected.channel), keeping: nil)
            .isEmpty)
}

@Test func aResendOfAHiddenOccurrenceShowsItAgain() {
    var state = ReadState()
    state.markRead(Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1)))
    let resent = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(70), lastEventKind: .resent)

    #expect(
        state.shown(own: [resent], feed: [], in: .channel(resent.channel), keeping: nil).map(\.id)
            == [1])
}

@Test func showingReadListsEveryOccurrenceAsBefore() {
    var state = ReadState()
    let read = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1))
    let unread = Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(2))
    state.markRead(read)
    state.setHidesRead(false, in: .channel(read.channel))

    #expect(
        state.shown(own: [unread, read], feed: [], in: .channel(read.channel), keeping: nil) == [
            unread, read,
        ])
}

@Test func hidingReadListsUnreadOccurrencesTheChannelHasNotPagedTo() {
    let state = ReadState()
    let channel = ChannelID(instance: "onprem", slug: "infra")
    let loaded = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(9))
    let older = Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(1))
    let elsewhere = Fixture.occurrence(
        id: 3, lastEventAt: Fixture.minutes(5), channel: ChannelID(instance: "cloud", slug: "infra")
    )

    let shown = state.shown(
        own: [loaded], feed: [loaded, elsewhere, older], in: .channel(channel), keeping: nil)

    #expect(shown.map(\.id) == [1, 2])
}

@Test func aNewerCopyInTheFeedBeatsAStaleOneInTheChannelsList() {
    var state = ReadState()
    let stale = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1))
    state.markRead(stale)
    let resent = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(70), lastEventKind: .resent)

    let hiding = state.shown(
        own: [stale], feed: [resent], in: .channel(stale.channel), keeping: nil)
    state.setHidesRead(false, in: .channel(stale.channel))
    let showing = state.shown(
        own: [stale], feed: [resent], in: .channel(stale.channel), keeping: nil)

    #expect(hiding == [resent])
    #expect(showing == [resent])
}

@Test func turningHidingOffKeepsTheSelectedOccurrenceFromTheFeed() {
    var state = ReadState()
    let loaded = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(9))
    let older = Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(1))
    state.markRead(older)
    state.setHidesRead(false, in: .channel(loaded.channel))

    let kept = state.shown(own: [loaded], feed: [older], in: .channel(loaded.channel), keeping: 2)
    let notKept = state.shown(
        own: [loaded], feed: [older], in: .channel(loaded.channel), keeping: nil)

    #expect(kept.map(\.id) == [1, 2])
    #expect(notKept.map(\.id) == [1])
}

@Test func liveHidesReadOnItsOwnSetting() throws {
    var state = ReadState()
    let infra = OccurrenceScope.channel(ChannelID(instance: "onprem", slug: "infra"))
    #expect(state.hidesRead(in: .allChannels))

    state.setHidesRead(false, in: .allChannels)

    #expect(!state.hidesRead(in: .allChannels))
    #expect(state.hidesRead(in: infra))
    let decoded = try JSONDecoder().decode(ReadState.self, from: JSONEncoder().encode(state))
    #expect(!decoded.hidesRead(in: .allChannels))
}

@Test func liveHidingReadShowsEveryChannelsUnreadAndTheLastClickedCard() {
    var state = ReadState()
    let unread = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(9))
    let clicked = Fixture.occurrence(
        id: 2, lastEventAt: Fixture.minutes(5), channel: ChannelID(instance: "cloud", slug: "apps"))
    let read = Fixture.occurrence(id: 3, lastEventAt: Fixture.minutes(1))
    state.markRead(clicked)
    state.markRead(read)
    let feed = [unread, clicked, read]

    #expect(state.shown(own: feed, feed: feed, in: .allChannels, keeping: 2).map(\.id) == [1, 2])
    #expect(state.shown(own: feed, feed: feed, in: .allChannels, keeping: nil).map(\.id) == [1])
}

@Test func liveShowsAResendAgainAndEverythingWhenShowingRead() {
    var state = ReadState()
    let read = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1))
    state.markRead(read)
    let resent = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(70), lastEventKind: .resent)
    let other = Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(2))
    state.markRead(other)

    #expect(
        state.shown(own: [resent, other], feed: [resent, other], in: .allChannels, keeping: nil)
            .map(\.id) == [1])
    state.setHidesRead(false, in: .allChannels)
    #expect(
        state.shown(own: [read, other], feed: [read, other], in: .allChannels, keeping: nil)
            == [other, read])
}

@Test func onATieTheListsOwnCopyWinsSoASilenceShows() {
    let state = ReadState()
    let feedCopy = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1))
    let silenced = Occurrence(
        id: 1, channel: feedCopy.channel, source: feedCopy.source, alert: feedCopy.alert,
        firstReceivedAt: feedCopy.firstReceivedAt, lastReceivedAt: feedCopy.lastReceivedAt,
        lastEventAt: feedCopy.lastEventAt, lastEventKind: .fired, notificationCount: 1,
        silencedUntil: Fixture.minutes(60))

    let shown = state.shown(
        own: [silenced], feed: [feedCopy], in: .channel(feedCopy.channel), keeping: nil)

    #expect(shown.map(\.silencedUntil) == [Fixture.minutes(60)])
}
