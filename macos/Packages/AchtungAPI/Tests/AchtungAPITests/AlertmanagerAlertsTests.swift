import AchtungDomain
import Foundation
import Testing

@testable import AchtungAPI

private func alerts(_ fixture: String, status: Int = 200, instance: String = "cdx")
    async throws(ServerError) -> AlertmanagerAlerts
{
    let route = "/api/alertmanagers/\(instance)/alerts"
    let transport = StubTransport(routes: [route: .init(status: status, fixture: fixture)])
    return try await AchtungServer(baseURL: URL(filePath: "/"), transport: transport)
        .alertmanagerAlerts(instance: instance)
}

/// Parses like OpenAPIRuntime's `.iso8601WithFractionalSeconds`.
private func date(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try #require(formatter.date(from: text))
}

@Test func mapsAnAlertmanagersAlerts() async throws {
    let list = try await alerts("alertmanager-alerts")

    #expect(list.instance == "cdx")
    #expect(list.status == .reachable(checkedAt: try date("2026-11-09T12:00:00.000Z")))
    #expect(list.alerts.map(\.fingerprint) == ["f1", "f2", "f3", "f4", "f5", "f6"])
    let first = list.alerts[0]
    #expect(first.title == "HighErrorRate")
    #expect(first.severity == .critical)
    #expect(first.summary == "5xx rate above 5% for 10 minutes.")
    #expect(first.startsAt == (try date("2026-11-09T09:40:00.000Z")))
    #expect(first.labels["service"] == "checkout-api")
    #expect(first.annotations["summary"] == "5xx rate above 5% for 10 minutes.")
    #expect(first.state == .active)
    #expect(first.occurrenceID == 9)
}

@Test func anAlertAchtungDoesNotHaveHasNoOccurrence() async throws {
    let missing = try await alerts("alertmanager-alerts").alerts[1]

    #expect(missing.occurrenceID == nil)
    #expect(missing.summary == nil)
}

@Test func mapsSilencedAndInhibitedStates() async throws {
    let list = try await alerts("alertmanager-alerts")

    #expect(list.alerts[3].state == .silenced(until: try date("2026-11-09T14:10:00.000Z")))
    // A silence Achtung doesn't know yet: silenced, until an unknown time.
    #expect(list.alerts[4].state == .silenced(until: nil))
    #expect(list.alerts[5].state == .inhibited)
    #expect(list.alerts[3].severity == .unknown)
}

@Test func anAlertmanagerNeverReadListsNothing() async throws {
    let list = try await alerts("alertmanager-alerts-never-read", instance: "lab")

    #expect(
        list.status == .unreachable(error: "connect ECONNREFUSED 10.0.0.9:9093", lastRead: nil))
    #expect(list.alerts.isEmpty)
}

@Test(arguments: [
    "alertmanager-alerts-reachable-never-read", "alertmanager-alerts-unreachable-no-error",
    "alertmanager-alerts-never-read-with-alerts", "alertmanager-alerts-active-silenced-until",
    "alertmanager-alerts-inhibited-silenced-until",
])
func anImpossibleListIsAnInvalidResponse(fixture: String) async {
    await #expect {
        try await alerts(fixture)
    } throws: { error in
        guard case ServerError.invalidResponse = error else { return false }
        return true
    }
}

@Test func anUnknownInstanceIsNotFound() async {
    await #expect(throws: ServerError.notFound("No Alertmanager for instance nope")) {
        try await alerts("alertmanager-not-found", status: 404, instance: "nope")
    }
}
