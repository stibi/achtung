import Foundation
import Testing

@testable import AchtungAPI

private let path = "/api/settings/ignored-alerts"

private func server(_ status: Int, _ fixture: String, log: RequestLog? = nil) -> AchtungServer {
    AchtungServer(
        baseURL: URL(filePath: "/"),
        transport: StubTransport(
            routes: [path: .init(status: status, fixture: fixture)], log: log))
}

@Test func readsTheIgnoredAlertNames() async throws {
    let names = try await server(200, "ignored-alerts").ignoredAlertNames()

    #expect(names == ["InfoInhibitor", "Watchdog", "grafana-irm-heartbeat"])
}

@Test func replacesTheWholeListAndReturnsItAsStored() async throws {
    let log = RequestLog()

    let names = try await server(200, "ignored-alerts", log: log)
        .setIgnoredAlertNames(["Watchdog", "InfoInhibitor", "grafana-irm-heartbeat"])

    #expect(names == ["InfoInhibitor", "Watchdog", "grafana-irm-heartbeat"])
    let body = try #require(await log.bodies.first)
    let sent = try JSONDecoder().decode([String: [String]].self, from: Data(body.utf8))
    #expect(sent == ["names": ["Watchdog", "InfoInhibitor", "grafana-irm-heartbeat"]])
}

@Test func aRejectedListSaysWhy() async {
    await #expect(throws: ServerError.rejected("names/0 must NOT have fewer than 1 characters")) {
        try await server(400, "ignored-alerts-rejected").setIgnoredAlertNames([""])
    }
}
