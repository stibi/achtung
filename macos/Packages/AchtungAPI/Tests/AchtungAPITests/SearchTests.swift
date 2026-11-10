import AchtungDomain
import Foundation
import Testing

@testable import AchtungAPI

// Searching every channel's occurrences (ADR 0017).

private func server(log: RequestLog, status: Int = 200, fixture: String = "feed-page-2")
    -> AchtungServer
{
    AchtungServer(
        baseURL: URL(filePath: "/"),
        transport: StubTransport(
            routes: ["/api/occurrences": .init(status: status, fixture: fixture)], log: log))
}

@Test func aSearchSendsItsTextAndFiltersAsQueryParameters() async throws {
    let log = RequestLog()
    let search = OccurrenceSearch(
        text: "disk full",
        tokens: [
            .label(name: "namespace", value: "payments"), .label(name: "job", value: "api"),
            .severity(.critical), .severity(.warning), .instance("cdx"),
        ])

    _ = try await server(log: log).occurrences(in: .search(search), after: "abc")

    let path = try #require(await log.paths.first)
    let items = try #require(URLComponents(string: path)?.queryItems)
    #expect(items.first { $0.name == "q" }?.value == "disk full")
    #expect(items.filter { $0.name == "label" }.map(\.value) == ["namespace=payments", "job=api"])
    #expect(items.filter { $0.name == "severity" }.map(\.value) == ["critical", "warning"])
    #expect(items.first { $0.name == "instance" }?.value == "cdx")
    #expect(items.first { $0.name == "cursor" }?.value == "abc")
}

@Test func aSearchWithOnlyTokensSendsNoText() async throws {
    let log = RequestLog()

    _ = try await server(log: log).occurrences(
        in: .search(OccurrenceSearch(text: "", tokens: [.instance("cdx")])))

    let path = try #require(await log.paths.first)
    let items = try #require(URLComponents(string: path)?.queryItems)
    #expect(items.map(\.name) == ["instance"])
}

@Test func aSearchTheServerRejectsSaysWhy() async {
    await #expect(throws: ServerError.rejected("Invalid cursor")) {
        try await server(log: RequestLog(), status: 400, fixture: "bad-cursor")
            .occurrences(in: .search(OccurrenceSearch(text: "x", tokens: [])))
    }
}
