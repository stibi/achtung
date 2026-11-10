import AchtungDomain
import Foundation
import Testing

@testable import AchtungAPI

// Ending an alert's silence (ADR 0015) and silencing several alerts at once (ADR 0016).

private func server(
    _ path: String, _ status: Int, _ fixture: String, log: RequestLog? = nil
) -> AchtungServer {
    AchtungServer(
        baseURL: URL(filePath: "/"),
        transport: StubTransport(routes: [path: .init(status: status, fixture: fixture)], log: log))
}

private func date(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try #require(formatter.date(from: text))
}

@Test func endingASilenceReturnsTheOccurrenceUnsilenced() async throws {
    let occurrence = try await server("/api/occurrences/4/silence", 200, "unsilence-ended")
        .unsilence(occurrenceID: 4)

    #expect(occurrence.id == 4)
    #expect(occurrence.silencedUntil == nil)
}

@Test func aBroaderSilenceStillShowsAfterTheOwnOneEnds() async throws {
    let occurrence = try await server("/api/occurrences/4/silence", 200, "unsilence-still-silenced")
        .unsilence(occurrenceID: 4)

    #expect(occurrence.silencedUntil == (try date("2026-11-09T06:00:00.000Z")))
}

@Test func onlyABroaderSilenceIsTheServersMessage() async {
    await #expect(
        throws: ServerError.silenceFailed(
            "Only a broader silence mutes this alert; end it in Alertmanager")
    ) {
        try await server("/api/occurrences/4/silence", 409, "unsilence-broader-only")
            .unsilence(occurrenceID: 4)
    }
}

@Test func silencingSeveralAlertsSendsThemAndMapsEachResult() async throws {
    let log = RequestLog()

    let results = try await server(
        "/api/alertmanagers/cdx/silences", 200, "alerts-silenced", log: log
    )
    .silenceAlerts(["c1", "gone"], of: "cdx", for: .fourHours)

    #expect(
        results == [
            AlertSilenceResult(
                fingerprint: "c1", outcome: .silenced(until: try date("2026-11-08T23:00:00.000Z"))),
            AlertSilenceResult(fingerprint: "gone", outcome: .failed("No longer in Alertmanager")),
        ])
    let body = try #require(await log.bodies.first)
    let sent = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    #expect(sent?["fingerprints"] as? [String] == ["c1", "gone"])
    #expect(sent?["durationSeconds"] as? Int == 14_400)
}

@Test(arguments: ["alerts-silenced-impossible", "alerts-silenced-both"])
func aResultWithNeitherOrBothOfAnEndAndAnErrorIsAnInvalidResponse(fixture: String) async {
    await #expect {
        try await server("/api/alertmanagers/cdx/silences", 200, fixture)
            .silenceAlerts(["c1"], of: "cdx", for: .oneHour)
    } throws: { error in
        if case ServerError.invalidResponse = error { true } else { false }
    }
}

@Test func endingASilenceThatFailsSaysWhy() async {
    await #expect(throws: ServerError.notFound("Occurrence not found")) {
        try await server("/api/occurrences/4/silence", 404, "occurrence-not-found")
            .unsilence(occurrenceID: 4)
    }
    await #expect(
        throws: ServerError.silenceFailed("Alertmanager refused the silence: connection timed out")
    ) {
        try await server("/api/occurrences/4/silence", 502, "silence-bad-gateway")
            .unsilence(occurrenceID: 4)
    }
}

@Test func silencingAnUnreachableAlertmanagersAlertsSaysWhy() async {
    await #expect(
        throws: ServerError.silenceFailed("Alertmanager refused the silence: connection timed out")
    ) {
        try await server("/api/alertmanagers/cdx/silences", 502, "silence-bad-gateway")
            .silenceAlerts(["c1"], of: "cdx", for: .oneHour)
    }
}
