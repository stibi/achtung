import AchtungDomain
import Foundation

extension AchtungServer {
    /// One page of every channel's occurrences that match `search` (ADR 0017), most
    /// recently changed first.
    func searchPage(_ search: OccurrenceSearch, after cursor: String?) async throws
        -> OccurrencePage
    {
        let query = Operations.ListOccurrences.Input.Query(
            cursor: cursor, q: search.text.isEmpty ? nil : search.text,
            label: search.labels.isEmpty ? nil : search.labels,
            severity: search.severities.isEmpty
                ? nil
                : search.severities.compactMap {
                    Operations.ListOccurrences.Input.Query.SeverityPayloadPayload(
                        rawValue: $0.rawValue)
                },
            instance: search.instance)
        switch try await client.listOccurrences(query: query) {
        case .ok(let response):
            return try OccurrencePage(response.body.json)
        case .badRequest(let response):
            throw ServerError.rejected(try response.body.json.error)
        case .undocumented(let status, _):
            throw ServerError.invalidResponse("HTTP \(status)")
        }
    }
}
