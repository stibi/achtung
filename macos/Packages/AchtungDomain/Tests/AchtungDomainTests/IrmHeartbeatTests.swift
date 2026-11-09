import AchtungDomain
import Foundation
import Testing

/// Minutes from `Fixture.start`, so the texts don't depend on the locale.
private func time(_ date: Date) -> String {
    "T+\(Int(date.timeIntervalSince(Fixture.start) / 60))"
}

/// Read at T+90 when known.
private func irm(_ known: IrmHeartbeat.Known?, error: String? = nil) -> IrmHeartbeat {
    IrmHeartbeat(
        status: known.map { .known($0, checkedAt: Fixture.minutes(90)) } ?? .unknown,
        error: error)
}

@Test func theHeartIsGreenRedOrGrey() {
    #expect(irm(.receiving(lastMissed: nil)).tone == .good)
    #expect(irm(.missing(since: Fixture.start)).tone == .bad)
    #expect(irm(nil, error: "timeout").tone == .unknown)
}

@Test func aKnownStatusIsStaleOnlyWhenTheLatestReadFailed() {
    #expect(!irm(.receiving(lastMissed: nil)).isStale)
    #expect(irm(.receiving(lastMissed: nil), error: "HTTP 502").isStale)
    #expect(irm(.missing(since: Fixture.start), error: "HTTP 502").isStale)
    // Never read: there is no older status to be stale.
    #expect(!irm(nil, error: "HTTP 502").isStale)
}

@Test func onlyAMissingHeartbeatWarnsOnTheTile() {
    #expect(
        irm(.missing(since: Fixture.minutes(5))).warning(time: time)
            == "IRM missing the heartbeat since T+5")
    #expect(irm(.receiving(lastMissed: nil)).warning(time: time) == nil)
    #expect(irm(nil).warning(time: time) == nil)
}

@Test func theHelpSaysWhenTheHeartbeatWasLastMissedAndForHowLong() {
    let missed = IrmHeartbeat.Missed(start: Fixture.minutes(10), end: Fixture.minutes(12))

    #expect(
        irm(.receiving(lastMissed: missed)).help(time: time)
            == "Grafana IRM is receiving the heartbeat. Last missed T+10, for 2m.")
    #expect(
        irm(.receiving(lastMissed: nil)).help(time: time)
            == "Grafana IRM is receiving the heartbeat. Never missed.")
}

@Test func theHelpAddsTheReadError() {
    #expect(
        irm(.missing(since: Fixture.minutes(5)), error: "HTTP 502").help(time: time)
            == "Grafana IRM is missing the heartbeat since T+5: it isn't getting it from this "
            + "Alertmanager. IRM couldn't be read just now (HTTP 502); this is from T+90.")
    #expect(
        irm(nil, error: "connect ECONNREFUSED").help(time: time)
            == "Grafana IRM's heartbeat is unknown: IRM was never read. "
            + "Reading IRM failed: connect ECONNREFUSED.")
}

@Test func voiceOverHearsTheStatusAndHowOldItIs() {
    #expect(irm(.receiving(lastMissed: nil)).accessibilityText(time: time) == "IRM receiving")
    #expect(
        irm(.missing(since: Fixture.minutes(5))).accessibilityText(time: time)
            == "IRM missing the heartbeat since T+5")
    #expect(
        irm(.receiving(lastMissed: nil), error: "HTTP 502").accessibilityText(time: time)
            == "IRM receiving, as of T+90")
    #expect(irm(nil, error: "timeout").accessibilityText(time: time) == "IRM unknown")
}
