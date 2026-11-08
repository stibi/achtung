import AchtungDomain
import Foundation
import Testing

@testable import AchtungAPI

private let base = URL(filePath: "/")
private let cursor = "WyIyMDI2LTExLTA3VDIxOjE0OjE5LjQ4NFoiLDFd"
private let crmProd = ChannelID(instance: "onprem", slug: "crm-prod")
private let page1 = "/api/instances/onprem/channels/crm-prod/occurrences"
private let page2 = "/api/instances/onprem/channels/crm-prod/occurrences?cursor=\(cursor)"

private func server(_ routes: [String: StubTransport.Route]) -> AchtungServer {
    AchtungServer(baseURL: base, transport: StubTransport(routes: routes))
}

private func ok(_ fixture: String) -> StubTransport.Route {
    .init(status: 200, fixture: fixture)
}

/// Parses like OpenAPIRuntime's `.iso8601WithFractionalSeconds`, so dates compare equal
/// to the decoded ones (another parser can round the milliseconds differently).
private func date(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try #require(formatter.date(from: text))
}

@Test func mapsChannels() async throws {
    let channels = try await server(["/api/channels": ok("channels")]).channels()

    // Sorted by instance, then name; both instances have a crm-prod.
    #expect(
        channels.map(\.id) == [
            ChannelID(instance: "default", slug: "crm-prod"),
            ChannelID(instance: "default", slug: "onepost-prod"),
            crmProd,
            ChannelID(instance: "onprem", slug: "legal-machine-dev"),
            ChannelID(instance: "onprem", slug: "legal-machine-prod"),
        ])
    #expect(channels[0].firing == 0)
    #expect(channels[0].lastEventAt == nil)
    #expect(channels[2].firing == 2)
    #expect(channels[2].lastEventAt == (try date("2026-11-07T21:14:19.526Z")))
}

@Test func mapsAPageOfOccurrences() async throws {
    let page = try await server([page1: ok("crm-prod-page-1")]).occurrences(
        in: .channel(crmProd))

    #expect(page.nextCursor == cursor)
    #expect(page.occurrences.map(\.id) == [4, 1])
    let firing = page.occurrences[0]
    #expect(firing.channel == crmProd)
    #expect(firing.source == "alertmanager")
    #expect(firing.alert.sourceKey == "c0ffee0000000001")
    #expect(firing.alert.severity == .warning)
    #expect(firing.alert.title == "PostgresReplicationLag")
    #expect(firing.alert.summary == "Replica is 45s behind primary.")
    #expect(firing.alert.labels["namespace"] == "example-prod")
    #expect(firing.alert.annotations == ["summary": "Replica is 45s behind primary."])
    #expect(
        firing.alert.links == [
            AlertLink(
                kind: .source,
                url: try #require(URL(string: "https://prometheus.example.com/graph")))
        ])
    #expect(firing.alert.startsAt == (try date("2026-11-07T18:00:00.000Z")))
    #expect(firing.alert.state == .firing)
    #expect(firing.lastEventAt == (try date("2026-11-07T21:14:19.526Z")))
    #expect(firing.notificationCount == 1)
    let resolved = page.occurrences[1]
    #expect(resolved.alert.state == .resolved(endsAt: try date("2026-10-13T08:42:00.000Z")))
    #expect(resolved.firstReceivedAt == (try date("2026-11-07T21:14:19.384Z")))
    #expect(resolved.lastReceivedAt == (try date("2026-11-07T21:14:19.484Z")))
    #expect(resolved.notificationCount == 2)
}

@Test func followsNextCursorToCollectEverythingChangedSince() async throws {
    let api = server([page1: ok("crm-prod-page-1"), page2: ok("crm-prod-page-2")])

    let changed = try await api.occurrences(in: .channel(crmProd), changedSince: .distantPast)

    #expect(changed.map(\.id) == [4, 1, 2])
}

@Test func stopsPagingOnceThePagesReachOlderChanges() async throws {
    // No route for page 2: requesting it would fail.
    let api = server([page1: ok("crm-prod-page-1")])

    let changed = try await api.occurrences(
        in: .channel(crmProd), changedSince: try date("2026-11-07T21:14:19.500Z"))

    // Page 1 already reaches an older change (occurrence 1), so page 2 is never asked
    // for; page 1 comes back whole, older occurrence included.
    #expect(changed.map(\.id) == [4, 1])
}

@Test func anOccurrenceChangedExactlyAtSinceIsNotOlderSoPagingGoesOn() async throws {
    let api = server([page1: ok("crm-prod-page-1"), page2: ok("crm-prod-page-2")])

    // Occurrence 1 changed exactly at `since`, so page 1 doesn't reach older changes and
    // page 2 is fetched; its occurrence 2 is older, so paging stops there.
    let changed = try await api.occurrences(
        in: .channel(crmProd), changedSince: try date("2026-11-07T21:14:19.484Z"))

    #expect(changed.map(\.id) == [4, 1, 2])
}

@Test func mapsAnOccurrenceWithItsHistory() async throws {
    let detail = try await server(["/api/occurrences/9": ok("occurrence-9")]).occurrence(id: 9)

    #expect(detail.occurrence.id == 9)
    #expect(detail.events.map(\.kind) == [.fired])
    #expect(detail.events[0].recordedAt == (try date("2026-11-07T21:14:19.643Z")))
    #expect(detail.otherOccurrences.map(\.id) == [7])
    #expect(
        detail.otherOccurrences[0].alert.state
            == .resolved(endsAt: try date("2026-11-07T18:20:00.000Z")))
}

@Test func mapsEveryEventKindLinkKindAndAMissingSummary() async throws {
    let detail = try await server(["/api/occurrences/12": ok("occurrence-reopened")])
        .occurrence(id: 12)

    #expect(detail.events.map(\.kind) == [.fired, .resolved, .reopened])
    #expect(detail.occurrence.alert.links.map(\.kind) == [.runbook, .dashboard])
    #expect(detail.occurrence.alert.severity == .unknown)
    #expect(detail.occurrence.alert.summary == nil)
    #expect(detail.occurrence.alert.labels.isEmpty)
}

@Test func reportsNotFoundAndRejectedRequestsWithTheServersMessage() async throws {
    let api = server([
        "/api/occurrences/99999": .init(status: 404, fixture: "occurrence-not-found"),
        "/api/instances/onprem/channels/crm-prod/occurrences?cursor=bogus": .init(
            status: 400, fixture: "bad-cursor"),
    ])

    await #expect(throws: ServerError.notFound("Occurrence not found")) {
        try await api.occurrence(id: 99999)
    }
    await #expect(throws: ServerError.rejected("Invalid cursor")) {
        try await api.occurrences(in: .channel(crmProd), after: "bogus")
    }
}

@Test func rejectsAFiringOccurrenceThatHasAnEnd() async {
    let api = server([page1: ok("firing-with-end")])

    await #expect(
        throws: ServerError.invalidResponse(
            "Occurrence 4 is firing with endsAt Optional(2026-11-07 21:00:00 +0000)")
    ) {
        try await api.occurrences(in: .channel(crmProd))
    }
}

@Test func anUndocumentedStatusIsAnInvalidResponse() async {
    let api = server(["/api/channels": .init(status: 500, fixture: "bad-cursor")])

    await #expect(throws: ServerError.invalidResponse("HTTP 500")) {
        try await api.channels()
    }
}

@Test func aTransportFailureMeansUnreachable() async {
    let error = await #expect(throws: ServerError.self) {
        try await server([:]).channels()
    }
    guard case .unreachable = error else {
        Issue.record("Expected unreachable, got \(String(describing: error))")
        return
    }
}

private let feed1 = "/api/occurrences"
private let feed2 = "/api/occurrences?cursor=WyIyMDI2LTExLTA3VDIxOjE0OjE5LjYxMFoiLDdd"

@Test func mapsTheFeedOfEveryChannelWithEachRowsChannel() async throws {
    let page = try await server([feed1: ok("feed-page-1")]).occurrences(in: .allChannels)

    #expect(page.occurrences.map(\.id) == [10, 9, 7])
    #expect(
        page.occurrences.map(\.channel) == [
            ChannelID(instance: "default", slug: "onepost-prod"),
            ChannelID(instance: "onprem", slug: "legal-machine-prod"),
            ChannelID(instance: "onprem", slug: "legal-machine-prod"),
        ])
    #expect(page.nextCursor == "WyIyMDI2LTExLTA3VDIxOjE0OjE5LjYxMFoiLDdd")
}

@Test func pagesTheFeedAcrossChannelsIncludingATieOnLastEventAt() async throws {
    let api = server([feed1: ok("feed-page-1"), feed2: ok("feed-page-2")])

    // Occurrences 6 and 5 changed at the same moment; 4 is older than `since`.
    let changed = try await api.occurrences(
        in: .allChannels, changedSince: try date("2026-11-07T21:14:19.553Z"))

    #expect(changed.map(\.id) == [10, 9, 7, 6, 5, 4])
}

@Test func reportsARejectedFeedCursor() async {
    let api = server(["/api/occurrences?cursor=bogus": .init(status: 400, fixture: "bad-cursor")])

    await #expect(throws: ServerError.rejected("Invalid cursor")) {
        try await api.occurrences(in: .allChannels, after: "bogus")
    }
}

@Test func mapsWhenAnOccurrenceIsSilencedUntil() async throws {
    let page = try await server([page1: ok("crm-prod-page-1")]).occurrences(in: .channel(crmProd))

    #expect(page.occurrences[0].silencedUntil == (try date("2026-11-07T22:14:19.526Z")))
    #expect(page.occurrences[1].silencedUntil == nil)
}

@Test func silencingSendsTheDurationAndReturnsTheSilencedOccurrence() async throws {
    let log = RequestLog()
    let api = AchtungServer(
        baseURL: base,
        transport: StubTransport(routes: ["/api/occurrences/4/silence": ok("silence-ok")], log: log)
    )

    let silenced = try await api.silence(occurrenceID: 4, for: .fourHours)

    #expect(silenced.id == 4)
    #expect(silenced.silencedUntil == (try date("2026-11-08T23:00:00.000Z")))
    let sent = try JSONSerialization.jsonObject(
        with: Data(try #require(await log.bodies.first).utf8))
    #expect((sent as? [String: Int]) == ["durationSeconds": 14_400])
}

@Test func aSilenceThatFailsCarriesTheServersReason() async {
    let api = server([
        "/api/occurrences/4/silence": .init(status: 409, fixture: "silence-conflict"),
        "/api/occurrences/9/silence": .init(status: 502, fixture: "silence-bad-gateway"),
        "/api/occurrences/99999/silence": .init(status: 404, fixture: "occurrence-not-found"),
    ])

    await #expect(
        throws: ServerError.silenceFailed("Instance default has no Alertmanager configured")
    ) {
        try await api.silence(occurrenceID: 4, for: .oneHour)
    }
    await #expect(
        throws: ServerError.silenceFailed("Alertmanager refused the silence: connection timed out")
    ) {
        try await api.silence(occurrenceID: 9, for: .oneHour)
    }
    await #expect(throws: ServerError.notFound("Occurrence not found")) {
        try await api.silence(occurrenceID: 99999, for: .oneHour)
    }
}
