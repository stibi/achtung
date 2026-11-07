import AchtungDomain
import SwiftUI

/// A channel's occurrences, most recently changed first. What changed since the user last
/// left the app sits above a "new" divider. Scrolling to the end loads older pages.
struct AlertList: View {
    let occurrences: [Occurrence]
    let readState: ReadState
    let hasOlder: Bool
    /// The last successful refresh; a failed page load retries after the next one.
    let lastUpdated: Date?
    let loadOlder: () async -> Void
    @Binding var selection: Int?

    var body: some View {
        if occurrences.isEmpty && !hasOlder {
            AllClearView()
        } else {
            let newOnes = occurrences.filter { readState.isNew($0) }
            List(selection: $selection) {
                rows(newOnes)
                if let seenUntil = readState.seenUntil, !newOnes.isEmpty {
                    NewDivider(seenUntil: seenUntil)
                }
                rows(occurrences.filter { !readState.isNew($0) })
                if hasOlder {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task(id: [occurrences.count, lastUpdated] as [AnyHashable?]) {
                            await loadOlder()
                        }
                }
            }
            .animation(.default, value: occurrences.map(\.id))
        }
    }

    private func rows(_ occurrences: [Occurrence]) -> some View {
        ForEach(occurrences) { occurrence in
            AlertRow(occurrence: occurrence, isRead: readState.isRead(occurrence))
        }
    }
}

#Preview {
    AlertList(
        occurrences: SampleData.occurrences, readState: SampleData.readState, hasOlder: false,
        lastUpdated: nil, loadOlder: {}, selection: .constant(nil))
}
