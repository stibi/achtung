import AchtungDomain
import Foundation
import Testing

private let infra = ChannelID(instance: "onprem", slug: "infra")
private let apps = ChannelID(instance: "cloud", slug: "apps")

@Test func markingAllReadMarksEveryUnreadOccurrenceOfTheChannelIncludingFeedOnes() {
    var state = ReadState()
    let loaded = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(9), channel: infra)
    let feedOnly = Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(1), channel: infra)
    let elsewhere = Fixture.occurrence(id: 3, lastEventAt: Fixture.minutes(5), channel: apps)
    let feed = [loaded, elsewhere, feedOnly]
    #expect(Set(state.unread(own: [loaded], feed: feed, in: .channel(infra)).map(\.id)) == [1, 2])

    state.markAllRead(own: [loaded], feed: feed, in: .channel(infra))

    #expect(state.isRead(loaded))
    #expect(state.isRead(feedOnly))
    #expect(!state.isRead(elsewhere))
    #expect(state.unread(own: [loaded], feed: feed, in: .channel(infra)).isEmpty)
}

@Test func markingAllReadInLiveMarksEveryChannel() {
    var state = ReadState()
    let feed = [
        Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(9), channel: infra),
        Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(5), channel: apps),
    ]

    state.markAllRead(own: feed, feed: feed, in: .allChannels)

    #expect(feed.allSatisfy(state.isRead))
    #expect(state.unread(own: feed, feed: feed, in: .allChannels).isEmpty)
}

@Test func whatChangesAfterMarkingAllReadStaysUnread() {
    var state = ReadState()
    let loaded = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(9), channel: infra)
    state.markAllRead(own: [loaded], feed: [loaded], in: .channel(infra))

    // Arrived after the last refresh: not loaded when marking, so not marked.
    let arrivedLater = Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(8), channel: infra)
    let resent = Fixture.occurrence(
        id: 1, lastEventAt: Fixture.minutes(70), channel: infra, lastEventKind: .resent)

    #expect(!state.isRead(arrivedLater))
    #expect(!state.isRead(resent))
}

@Test func nothingToMarkWhenEverythingIsRead() {
    var state = ReadState()
    let read = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1), channel: infra)
    state.markRead(read)

    #expect(state.unread(own: [read], feed: [read], in: .channel(infra)).isEmpty)
    #expect(state.unread(own: [], feed: [], in: .allChannels).isEmpty)
}

@Test func markingAllReadUsesTheLatestCopyOfAnOccurrence() {
    var state = ReadState()
    let stale = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1), channel: infra)
    let latest = Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(9), channel: infra)

    state.markAllRead(own: [stale], feed: [latest], in: .channel(infra))

    #expect(state.isRead(latest))
}
