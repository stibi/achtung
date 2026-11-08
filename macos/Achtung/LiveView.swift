import AchtungDomain
import SwiftUI

/// Every channel's occurrences as one stream, most recently changed first, each with all
/// its details. What changed since the user last left the app sits above a "new" divider.
/// Scrolling to the end loads older pages. Beside it, the last 24 hours as a timeline
/// (`LiveTimeline`); clicking a marker scrolls to its card and highlights it. The timeline
/// goes away before the cards would get narrower than `minimumCardsWidth`.
struct LiveView: View {
    private static let minimumCardsWidth: CGFloat = 520
    private static let timelineMargin: CGFloat = 10

    let occurrences: [Occurrence]
    /// Everything firing now, for the timeline's bars of alerts older than its 24 hours.
    let firing: [Occurrence]
    let readState: ReadState
    let hasOlder: Bool
    /// The last successful refresh; a failed page load retries after the next one.
    let lastUpdated: Date?
    let loadOlder: () async -> Void
    let markRead: (Occurrence) -> Void
    let silence: SilenceAction

    /// The card a timeline marker was clicked for, highlighted for a moment.
    @State private var highlighted: Int?
    /// Counts clicks, so each one restarts the highlight's two seconds, even on the same
    /// card.
    @State private var highlightRequest = 0

    var body: some View {
        if occurrences.isEmpty && !hasOlder {
            AllClearView()
        } else {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        cards
                        if geometry.size.width
                            >= Self.minimumCardsWidth + LiveTimeline.width + Self.timelineMargin
                        {
                            LiveTimeline(occurrences: occurrences + firing, readState: readState) {
                                show($0, with: proxy)
                            }
                            .frame(width: LiveTimeline.width)
                            .paneCard()
                            .padding([.top, .trailing, .bottom], Self.timelineMargin)
                        }
                    }
                }
            }
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                OccurrenceStream(
                    occurrences: occurrences, readState: readState, hasOlder: hasOlder,
                    lastUpdated: lastUpdated, loadOlder: loadOlder
                ) { occurrence in
                    LiveCard(
                        occurrence: occurrence, isRead: readState.isRead(occurrence),
                        isHighlighted: highlighted == occurrence.id, silence: silence
                    )
                    .id(occurrence.id)
                    .simultaneousGesture(TapGesture().onEnded { markRead(occurrence) })
                }
            }
            .padding(24)
            .animation(.default, value: occurrences.map(\.id))
        }
        // Ends the highlight two seconds after the latest click; a new click restarts it.
        .task(id: highlightRequest) {
            guard highlighted != nil else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return  // Cancelled: another click, or the view went away.
            }
            withAnimation { highlighted = nil }
        }
    }

    /// Scrolls the stream to `occurrence`'s card and highlights it for two seconds.
    private func show(_ occurrence: Occurrence, with proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo(occurrence.id, anchor: .top)
        }
        highlighted = occurrence.id
        highlightRequest += 1
    }
}

/// One occurrence with all its details. Unread cards carry a dot (a circular arrow when
/// resent) and an accent border;
/// clicking a card marks it read, which fades it.
private struct LiveCard: View {
    let occurrence: Occurrence
    let isRead: Bool
    /// Shown briefly after a timeline marker was clicked.
    let isHighlighted: Bool
    let silence: SilenceAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                UnreadMark(occurrence: occurrence, isRead: isRead)
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
        .opacity(isRead && !isHighlighted ? 0.6 : 1)
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .contentShape(.rect(cornerRadius: 14))
    }
}

#Preview {
    LiveView(
        occurrences: SampleData.occurrences, firing: [], readState: SampleData.readState,
        hasOlder: false, lastUpdated: nil, loadOlder: {}, markRead: { _ in },
        silence: { _, _ in nil })
}
