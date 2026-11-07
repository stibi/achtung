import AchtungDomain
import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func alert(_ sourceKey: String, startsAt: Date = start, state: AlertState = .firing)
    -> IncomingAlert
{
    IncomingAlert(
        sourceKey: sourceKey, severity: .critical, title: sourceKey, summary: nil, labels: [:],
        annotations: [:], startsAt: startsAt, links: [], state: state)
}

private func minutes(_ value: Double) -> Date {
    start.addingTimeInterval(value * 60)
}

@Test func newOccurrencesAreUnreadAndListedNewestFirst() {
    var inbox = Inbox(channels: ["infra", "apps"], seenUntil: nil)
    inbox.receive(alert("a"), in: "infra", at: minutes(1))
    inbox.receive(alert("b"), in: "apps", at: minutes(3))
    inbox.receive(alert("c"), in: "infra", at: minutes(2))

    #expect(inbox.entries.map(\.alert.sourceKey) == ["b", "c", "a"])
    #expect(inbox.entries(in: "infra").map(\.alert.sourceKey) == ["c", "a"])
    #expect(inbox.unreadCount == 3)
    #expect(inbox.unreadCount(in: "infra") == 2)
}

@Test func readingAnOccurrenceRemovesItFromTheUnreadCount() {
    var inbox = Inbox(channels: ["infra"], seenUntil: nil)
    inbox.receive(alert("a"), in: "infra", at: minutes(1))
    inbox.receive(alert("b"), in: "infra", at: minutes(2))
    let id = inbox.entries[0].id

    inbox.markRead(id)

    #expect(inbox.isRead(id))
    #expect(!inbox.isRead(inbox.entries[1].id))
    #expect(inbox.unreadCount(in: "infra") == 1)
}

@Test func aResolutionUpdatesInPlaceWithoutBecomingNewOrUnread() {
    var inbox = Inbox(channels: ["infra"], seenUntil: minutes(5))
    inbox.receive(alert("a"), in: "infra", at: minutes(1))
    inbox.markRead(inbox.entries[0].id)

    inbox.receive(alert("a", state: .resolved(endsAt: minutes(9))), in: "infra", at: minutes(10))

    #expect(inbox.entries.count == 1)
    #expect(inbox.entries[0].alert.state == .resolved(endsAt: minutes(9)))
    #expect(inbox.entries[0].receivedAt == minutes(1))
    #expect(!inbox.isNew(inbox.entries[0]))
    #expect(inbox.unreadCount == 0)
}

@Test func aRefireAfterResolveIsANewOccurrence() {
    var inbox = Inbox(channels: ["infra"], seenUntil: nil)
    inbox.receive(alert("a"), in: "infra", at: minutes(1))
    inbox.markRead(inbox.entries[0].id)

    inbox.receive(alert("a", startsAt: minutes(20)), in: "infra", at: minutes(20))

    #expect(inbox.entries.count == 2)
    #expect(inbox.unreadCount == 1)
}

@Test func entriesReceivedAfterTheUserLeftAreNew() {
    var inbox = Inbox(channels: ["infra"], seenUntil: nil)
    inbox.receive(alert("a"), in: "infra", at: minutes(1))
    #expect(!inbox.isNew(inbox.entries[0]))

    inbox.markSeen(at: minutes(2))
    inbox.receive(alert("b"), in: "infra", at: minutes(3))

    #expect(inbox.seenUntil == minutes(2))
    #expect(inbox.entries.map { inbox.isNew($0) } == [true, false])
}
