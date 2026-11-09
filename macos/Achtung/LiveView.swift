import AchtungDomain
import SwiftUI

/// Every channel's occurrences as one stream, most recently changed first, each with all
/// its details. What changed since the user last left the app sits above a "new" divider.
/// Scrolling to the end loads older pages. Beside it, the last 24 hours as a timeline
/// (`LiveTimeline`); clicking a marker scrolls to its card and highlights it. The timeline
/// goes away before the cards would get narrower than `minimumCardsWidth`. With read
/// alerts hidden, the stream holds only new ones and resends, and the card last clicked
/// (or shown from the timeline) until another is; the timeline still shows everything.
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
    @Binding var hidesRead: Bool
    let markRead: (Occurrence) -> Void
    let silence: SilenceAction

    /// The card a timeline marker was clicked for, highlighted for a moment.
    @State private var highlighted: Int?
    /// Counts clicks, so each one restarts the highlight's two seconds, even on the same
    /// card.
    @State private var highlightRequest = 0
    /// The card the user last clicked or showed from the timeline. It stays in the stream
    /// once read, until another one takes its place.
    @State private var kept: Int?

    private var shown: [Occurrence] {
        readState.shown(own: occurrences, feed: occurrences, in: .allChannels, keeping: kept)
    }

    var body: some View {
        if occurrences.isEmpty && !hasOlder {
            AllClearView()
        } else {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if shown.isEmpty && hidesRead {
                            CaughtUpView(coffeeBreak: true) { hidesRead = false }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            cards(proxy)
                        }
                        if geometry.size.width
                            >= Self.minimumCardsWidth + LiveTimeline.width + Self.timelineMargin
                        {
                            LiveTimeline(occurrences: occurrences + firing, readState: readState) {
                                show($0)
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

    private func cards(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // Older pages hold read alerts only: the feed is loaded down to the read
                // baseline, so while they're hidden there's nothing more to load.
                OccurrenceStream(
                    occurrences: shown, readState: readState, hasOlder: hasOlder && !hidesRead,
                    lastUpdated: lastUpdated, loadOlder: loadOlder
                ) { occurrence in
                    LiveCard(
                        occurrence: occurrence, isRead: readState.isRead(occurrence),
                        isHighlighted: highlighted == occurrence.id, silence: silence
                    )
                    .id(occurrence.id)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            kept = occurrence.id
                            markRead(occurrence)
                        })
                }
            }
            .padding(24)
            .animation(.default, value: shown.map(\.id))
        }
        // After the update that put a hidden card back into the stream, so it's there to
        // scroll to; on appearing too, for a click while the stream was all caught up.
        .onChange(of: highlightRequest) { scroll(to: highlighted, with: proxy) }
        .onAppear { scroll(to: highlighted, with: proxy) }
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
    /// A read card hidden from the stream comes back first, as the one the user has open.
    private func show(_ occurrence: Occurrence) {
        kept = occurrence.id
        highlighted = occurrence.id
        highlightRequest += 1
    }

    private func scroll(to id: Int?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation {
            proxy.scrollTo(id, anchor: .top)
        }
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
        hasOlder: false, lastUpdated: nil, loadOlder: {}, hidesRead: .constant(false),
        markRead: { _ in },
        silence: { _, _ in nil })
}
