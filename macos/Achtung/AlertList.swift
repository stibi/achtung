import AchtungDomain
import SwiftUI

/// A channel's alerts, newest first. Entries received since the user last left the app sit
/// above a "new" divider.
struct AlertList: View {
    let entries: [InboxEntry]
    let inbox: Inbox
    @Binding var selection: OccurrenceID?

    var body: some View {
        if entries.isEmpty {
            AllClearView()
        } else {
            let newEntries = entries.filter { inbox.isNew($0) }
            List(selection: $selection) {
                rows(newEntries)
                if let seenUntil = inbox.seenUntil, !newEntries.isEmpty {
                    NewDivider(seenUntil: seenUntil)
                }
                rows(entries.filter { !inbox.isNew($0) })
            }
            .animation(.default, value: entries.map(\.id))
        }
    }

    private func rows(_ entries: [InboxEntry]) -> some View {
        ForEach(entries) { entry in
            AlertRow(entry: entry, isRead: inbox.isRead(entry.id))
        }
    }
}
