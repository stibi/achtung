import AchtungDomain
import SwiftUI

/// The rows every occurrence list shares, for a `List` or a `LazyVStack` to hold: what
/// changed since the user last left the app, a "new" divider, the rest, and at the end a
/// row that loads the next older page when it appears.
struct OccurrenceStream<Row: View>: View {
    let occurrences: [Occurrence]
    let readState: ReadState
    let hasOlder: Bool
    /// The last successful refresh; a failed page load retries after the next one.
    let lastUpdated: Date?
    let loadOlder: () async -> Void
    @ViewBuilder let row: (Occurrence) -> Row

    var body: some View {
        let newOnes = occurrences.filter { readState.isNew($0) }
        ForEach(newOnes, content: row)
        if let seenUntil = readState.seenUntil, !newOnes.isEmpty {
            NewDivider(seenUntil: seenUntil)
        }
        ForEach(occurrences.filter { !readState.isNew($0) }, content: row)
        if hasOlder {
            ProgressView()
                .frame(maxWidth: .infinity)
                .task(id: [occurrences.count, lastUpdated] as [AnyHashable?]) {
                    await loadOlder()
                }
        }
    }
}
