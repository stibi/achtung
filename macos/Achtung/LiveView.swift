import AchtungDomain
import SwiftUI

/// Every channel's alerts as one stream, newest first, each with all its details. Entries
/// received since the user last left the app sit above a "new" divider.
struct LiveView: View {
    let inbox: Inbox
    let markRead: (OccurrenceID) -> Void

    var body: some View {
        if inbox.entries.isEmpty {
            AllClearView()
        } else {
            let newEntries = inbox.entries.filter { inbox.isNew($0) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    cards(newEntries)
                    if let seenUntil = inbox.seenUntil, !newEntries.isEmpty {
                        NewDivider(seenUntil: seenUntil)
                    }
                    cards(inbox.entries.filter { !inbox.isNew($0) })
                }
                .padding(24)
                .animation(.default, value: inbox.entries.map(\.id))
            }
        }
    }

    private func cards(_ entries: [InboxEntry]) -> some View {
        ForEach(entries) { entry in
            LiveCard(entry: entry, isRead: inbox.isRead(entry.id))
                .simultaneousGesture(TapGesture().onEnded { markRead(entry.id) })
        }
    }
}

/// One alert with all its details. Unread cards carry a dot and an accent border; clicking
/// a card marks it read, which fades it.
private struct LiveCard: View {
    let entry: InboxEntry
    let isRead: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRead ? Color.clear : Color.accentColor)
                    .frame(width: 8, height: 8)
                Text("#\(entry.channel)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            AlertDetails(alert: entry.alert)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isRead ? Color.clear : Color.accentColor.opacity(0.5))
        }
        .opacity(isRead ? 0.6 : 1)
        .contentShape(.rect(cornerRadius: 14))
    }
}
