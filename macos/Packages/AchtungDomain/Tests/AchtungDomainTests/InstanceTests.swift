import AchtungDomain
import Testing

private let alpha = ChannelID(instance: "alpha", slug: "web")
private let zuluDB = ChannelID(instance: "zulu", slug: "db")
private let zuluAPI = ChannelID(instance: "zulu", slug: "api")
private let zuluCron = ChannelID(instance: "zulu", slug: "cron")

private func channel(_ id: ChannelID) -> Channel {
    Fixture.channel(id.slug, instance: id.instance, firing: 0, lastEventAt: nil)
}

@Test func countsUnreadAndUnreadCriticalPerChannelAndInstance() {
    var state = ReadState()
    let occurrences = [
        Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1), channel: zuluDB),
        Fixture.occurrence(
            id: 2, lastEventAt: Fixture.minutes(2), channel: zuluDB, severity: .warning),
        Fixture.occurrence(id: 3, lastEventAt: Fixture.minutes(3), channel: zuluAPI),
        Fixture.occurrence(id: 4, lastEventAt: Fixture.minutes(4), channel: zuluAPI),
    ]
    state.markRead(occurrences[3])

    let sidebar = Instance.sidebar(
        channels: [channel(zuluAPI), channel(zuluDB)], occurrences: occurrences, readState: state)

    let zulu = sidebar[0]
    #expect(zulu.channels.map(\.id) == [zuluAPI, zuluDB])
    #expect(zulu.channels.map(\.unread) == [1, 2])
    #expect(zulu.channels.map(\.unreadCritical) == [1, 1])
    #expect(zulu.unread == 3)
    #expect(zulu.unreadCritical == 2)
}

@Test func somethingUnreadComesFirstThenEachGroupByName() {
    let occurrences = [
        Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1), channel: zuluDB),
        Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(1), channel: zuluCron),
    ]

    let sidebar = Instance.sidebar(
        channels: [channel(alpha), channel(zuluAPI), channel(zuluCron), channel(zuluDB)],
        occurrences: occurrences, readState: ReadState())

    // zulu has unread, alpha doesn't; inside zulu, cron and db (unread) before api.
    #expect(sidebar.map(\.name) == ["zulu", "alpha"])
    #expect(sidebar[0].channels.map(\.id) == [zuluCron, zuluDB, zuluAPI])
    #expect(sidebar.map(\.isAllRead) == [false, true])
    #expect(sidebar[0].channels.map(\.isAllRead) == [false, false, true])
}

@Test func occurrencesOfUnknownChannelsAreIgnored() {
    let sidebar = Instance.sidebar(
        channels: [channel(alpha)],
        occurrences: [Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(1), channel: zuluDB)],
        readState: ReadState())

    #expect(sidebar.map(\.name) == ["alpha"])
    #expect(sidebar[0].unread == 0)
}

@Test func noChannelsMeansNoInstances() {
    #expect(Instance.sidebar(channels: [], occurrences: [], readState: ReadState()).isEmpty)
}

@Test func namesSortAlphabeticallyIgnoringCase() {
    let sidebar = Instance.sidebar(
        channels: [
            channel(ChannelID(instance: "Prod", slug: "web")),
            channel(ChannelID(instance: "dev", slug: "web")),
        ],
        occurrences: [], readState: ReadState())

    #expect(sidebar.map(\.name) == ["dev", "Prod"])
}
