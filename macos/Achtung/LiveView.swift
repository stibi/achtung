import AchtungDomain
import SwiftUI

/// Every channel's occurrences as one stream, most recently changed first, each with all
/// its details. What changed since the user last left the app sits above a "new" divider.
/// Scrolling to the end loads older pages.
struct LiveView: View {
    let occurrences: [Occurrence]
    let readState: ReadState
    let hasOlder: Bool
    /// The last successful refresh; a failed page load retries after the next one.
    let lastUpdated: Date?
    let loadOlder: () async -> Void
    let markRead: (Occurrence) -> Void
    let silence: SilenceAction

    var body: some View {
        if occurrences.isEmpty && !hasOlder {
            AllClearView()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    OccurrenceStream(
                        occurrences: occurrences, readState: readState, hasOlder: hasOlder,
                        lastUpdated: lastUpdated, loadOlder: loadOlder
                    ) { occurrence in
                        LiveCard(
                            occurrence: occurrence, isRead: readState.isRead(occurrence),
                            silence: silence
                        )
                        .simultaneousGesture(TapGesture().onEnded { markRead(occurrence) })
                    }
                }
                .padding(24)
                .animation(.default, value: occurrences.map(\.id))
            }
        }
    }
}

/// One occurrence with all its details. Unread cards carry a dot and an accent border;
/// clicking a card marks it read, which fades it.
private struct LiveCard: View {
    let occurrence: Occurrence
    let isRead: Bool
    let silence: SilenceAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRead ? Color.clear : Color.accentColor)
                    .frame(width: 8, height: 8)
                Text("\(occurrence.channel.instance) · #\(occurrence.channel.slug)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 24) {
                AlertDetails(occurrence: occurrence, silence: silence)
                OccurrenceFacts(occurrence: occurrence)
            }
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

#Preview {
    LiveView(
        occurrences: SampleData.occurrences, readState: SampleData.readState, hasOlder: false,
        lastUpdated: nil, loadOlder: {}, markRead: { _ in }, silence: { _, _ in nil })
}
