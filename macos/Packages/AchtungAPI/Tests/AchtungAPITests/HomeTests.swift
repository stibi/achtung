import AchtungDomain
import Foundation
import Testing

@testable import AchtungAPI

private func home(_ fixture: String) async throws(ServerError) -> Home {
    let transport = StubTransport(routes: ["/api/home": .init(status: 200, fixture: fixture)])
    return try await AchtungServer(baseURL: URL(filePath: "/"), transport: transport).home()
}

/// Parses like OpenAPIRuntime's `.iso8601WithFractionalSeconds`.
private func date(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try #require(formatter.date(from: text))
}

@Test func mapsEachAlertmanagersLastRead() async throws {
    let alertmanagers = try await home("home").alertmanagers

    #expect(alertmanagers.map(\.instance) == ["cdx", "lab", "onprem", "staging"])
    let cdx = alertmanagers[0]
    #expect(cdx.isReachable)
    let read = try #require(cdx.lastRead)
    #expect(read.checkedAt == (try date("2026-11-09T12:00:00.000Z")))
    #expect(
        read.open
            == OpenAlertCounts(total: 15, critical: 3, warning: 8, info: 2, other: 2))
    #expect(read.silenced == 4)
    #expect(read.inhibited == 1)
    #expect(read.watchdogFires)
    #expect(
        read.delivery.missingInAchtung.map(\.title) == ["DiskWillFillIn4Hours", "KubeJobFailed"])
    #expect(read.delivery.missingInAchtung.map(\.severity) == [.critical, .unknown])
    #expect(read.delivery.staleInAchtung.map(\.id) == [4])
}

/// open and delivery are nullable objects (`nullable` with `allOf`): null must decode.
@Test func anAlertmanagerNeverReadHasNoLastRead() async throws {
    let lab = try await home("home").alertmanagers[1]

    #expect(lab.status == .unreachable(error: "connect ECONNREFUSED 10.0.0.9:9093", lastRead: nil))
}

@Test func anUnreachableAlertmanagerKeepsItsLastRead() async throws {
    let staging = try await home("home").alertmanagers[3]

    guard case .unreachable(let error, let lastRead) = staging.status else {
        Issue.record("staging should be unreachable")
        return
    }
    #expect(error == "Alertmanager answered HTTP 503")
    let read = try #require(lastRead)
    #expect(read.checkedAt == (try date("2026-11-09T11:31:00.000Z")))
    #expect(read.open.total == 2)
    #expect(!read.watchdogFires)
    #expect(read.delivery.summary == nil)
}

@Test func mapsSilencesAndTheNoisiestAndLongestFiringAlerts() async throws {
    let home = try await home("home")

    #expect(home.silences.map(\.instance) == ["cdx", "onprem"])
    let silence = home.silences[0]
    #expect(silence.createdBy == "ops@example.com")
    #expect(silence.endsAt == (try date("2026-11-09T14:10:00.000Z")))
    #expect(silence.summary == "DiskWillFillIn4Hours · namespace=logging")
    #expect(home.silences[1].matchers.first?.isRegex == true)
    #expect(home.noisiest.map(\.events) == [7, 3])
    #expect(home.noisiest.map(\.occurrence.id) == [9, 4])
    #expect(home.longestFiring.map(\.id) == [4, 9])
}

@Test(arguments: ["home-partial-read", "home-reachable-never-read", "home-unreachable-no-error"])
func anImpossibleAlertmanagerStateIsAnInvalidResponse(fixture: String) async {
    await #expect {
        try await home(fixture)
    } throws: { error in
        guard case ServerError.invalidResponse(let message) = error else { return false }
        return message.contains("cdx")
    }
}

@Test func mapsEachAlertmanagersIrmHeartbeat() async throws {
    let alertmanagers = try await home("home").alertmanagers

    #expect(
        alertmanagers[0].irm
            == IrmHeartbeat(
                status: .known(
                    .receiving(
                        lastMissed: .init(
                            start: try date("2026-11-08T16:52:00.000Z"),
                            end: try date("2026-11-08T16:54:00.000Z"))),
                    checkedAt: try date("2026-11-09T11:59:30.000Z")),
                error: nil))
    #expect(
        alertmanagers[1].irm
            == IrmHeartbeat(status: .unknown, error: "Grafana IRM answered HTTP 401"))
    #expect(
        alertmanagers[2].irm?.status
            == .known(
                .missing(since: try date("2026-11-09T11:40:00.000Z")),
                checkedAt: try date("2026-11-09T11:59:30.000Z")))
    // No IRM integration: nothing to show.
    #expect(alertmanagers[3].irm == nil)
}

@Test func anIrmHeartbeatFromAnEarlierReadKeepsItsStatusAndTheError() async throws {
    let irm = try #require(try await home("home-irm-stale").alertmanagers[0].irm)

    #expect(
        irm.status
            == .known(.receiving(lastMissed: nil), checkedAt: try date("2026-11-09T11:55:00.000Z")))
    #expect(irm.error == "Grafana IRM answered HTTP 502")
    #expect(irm.isStale)
}

@Test(arguments: [
    "home-irm-missing-without-since", "home-irm-one-ended-miss", "home-irm-known-never-read",
    "home-irm-unknown-but-read",
])
func anImpossibleIrmHeartbeatIsAnInvalidResponse(fixture: String) async {
    await #expect {
        try await home(fixture)
    } throws: { error in
        guard case ServerError.invalidResponse(let message) = error else { return false }
        return message.contains("cdx")
    }
}
