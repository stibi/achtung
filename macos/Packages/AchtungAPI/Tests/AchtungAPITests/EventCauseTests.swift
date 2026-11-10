import AchtungDomain
import Foundation
import Testing

@testable import AchtungAPI

/// An event's `cause` (ADR 0014): null when a notification caused it, else why Achtung
/// recorded it itself.
private func detail(_ fixture: String) async throws(ServerError) -> OccurrenceDetail {
    let transport = StubTransport(routes: [
        "/api/occurrences/12": .init(status: 200, fixture: fixture)
    ])
    return try await AchtungServer(baseURL: URL(filePath: "/"), transport: transport)
        .occurrence(id: 12)
}

@Test func mapsAResolveAchtungRecordedItselfAsVanished() async throws {
    let detail = try await detail("occurrence-vanished")

    #expect(detail.events.map(\.kind) == [.fired, .resolved])
    #expect(detail.events.map(\.cause) == [nil, .vanished])
    #expect(detail.occurrence.lastEventKind == .resolved)
}

@Test func anEventCauseTheClientDoesntKnowIsAnInvalidResponse() async {
    await #expect {
        try await detail("occurrence-unknown-cause")
    } throws: { error in
        if case ServerError.invalidResponse = error { true } else { false }
    }
}
