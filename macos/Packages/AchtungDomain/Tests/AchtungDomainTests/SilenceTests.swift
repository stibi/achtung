import AchtungDomain
import Foundation
import Testing

@Test(arguments: [
    (SilenceDuration.oneHour, 3600), (.fourHours, 14_400), (.oneDay, 86_400), (.oneWeek, 604_800),
])
func silenceDurations(duration: SilenceDuration, seconds: Int) {
    #expect(duration.seconds == seconds)
    // Stored as the app's remembered default, so the raw value must stay stable.
    #expect(SilenceDuration(rawValue: duration.rawValue) == duration)
}

@Test func anOccurrenceIsSilencedUntilItsSilenceEnds() {
    let silenced = Occurrence(
        id: 1, channel: ChannelID(instance: "onprem", slug: "infra"), source: "alertmanager",
        alert: Fixture.occurrence(id: 1, lastEventAt: Fixture.minutes(0)).alert,
        firstReceivedAt: Fixture.start, lastReceivedAt: Fixture.start,
        lastEventAt: Fixture.start, notificationCount: 1, silencedUntil: Fixture.minutes(60))

    #expect(silenced.isSilenced(at: Fixture.minutes(59)))
    #expect(!silenced.isSilenced(at: Fixture.minutes(60)))
    #expect(
        !Fixture.occurrence(id: 2, lastEventAt: Fixture.minutes(0)).isSilenced(
            at: Fixture.minutes(1)))
}
