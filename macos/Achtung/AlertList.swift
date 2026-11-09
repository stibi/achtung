import AchtungDomain
import SwiftUI

/// A channel's occurrences, most recently changed first. What changed since the user last
/// left the app sits above a "new" divider. Scrolling to the end loads older pages. With
/// read alerts hidden, only new ones and resends are listed, and an empty list says so.
struct AlertList: View {
    let occurrences: [Occurrence]
    let readState: ReadState
    let hasOlder: Bool
    /// The last successful refresh; a failed page load retries after the next one.
    let lastUpdated: Date?
    let loadOlder: () async -> Void
    @Binding var hidesRead: Bool
    @Binding var selection: Int?

    var body: some View {
        if occurrences.isEmpty && hidesRead {
            CaughtUpView { hidesRead = false }
        } else if occurrences.isEmpty && !hasOlder {
            AllClearView()
        } else {
            List(selection: $selection) {
                OccurrenceStream(
                    occurrences: occurrences, readState: readState, hasOlder: hasOlder,
                    lastUpdated: lastUpdated, loadOlder: loadOlder
                ) { occurrence in
                    AlertRow(occurrence: occurrence, isRead: readState.isRead(occurrence))
                }
            }
            .animation(.default, value: occurrences.map(\.id))
        }
    }
}

#Preview {
    AlertList(
        occurrences: SampleData.occurrences, readState: SampleData.readState, hasOlder: false,
        lastUpdated: nil, loadOlder: {}, hidesRead: .constant(false),
        selection: .constant(nil))
}
