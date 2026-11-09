import AchtungDomain
import SwiftUI

/// Home's three lists under the tiles: silences ending soon, the noisiest alerts of the
/// last 24 hours and the longest firing, each a `FittedSection`. Rows with an occurrence
/// open it in its channel. Together they fit the height left under the tiles, so Home
/// needs no scroll bar until the user asks for more.
struct HomeSections: View {
    /// Three sections of 260 and the gaps between them: below this, they stack.
    private static let sideBySideWidth: CGFloat = 3 * 260 + 2 * spacing
    private static let spacing: CGFloat = 16

    let home: Home
    /// The size there is for the sections: the page's width, and the height left under
    /// the tiles. The width comes from the window, not from the sections, which would
    /// otherwise keep themselves side by side once they were.
    let available: CGSize
    /// Changes when the user reloads Home, which collapses expanded sections.
    let collapseRequest: Int
    let open: (Occurrence) -> Void

    /// What each section needs to show all its rows, by title (`FittedSectionNeeds`).
    @State private var needs: [String: CGFloat] = [:]

    private enum Title {
        static let silences = "Silences ending soon"
        static let noisiest = "Noisiest, 24h"
        static let longest = "Longest firing"
        static let all = [silences, noisiest, longest]
    }

    var body: some View {
        let sideBySide = available.width >= Self.sideBySideWidth
        let budgets = budgets(sideBySide: sideBySide)
        // One layout that changes, rather than two stacks, so the sections keep what they
        // measured and whether they're expanded when the window crosses the width.
        let layout =
            sideBySide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Self.spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Self.spacing))
        layout { sections(budgets) }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onPreferenceChange(FittedSectionNeeds.self) { needs = $0 }
    }

    /// Side by side, each has the whole height; stacked, they share it (`ListFit.share`).
    private func budgets(sideBySide: Bool) -> [String: CGFloat] {
        guard !sideBySide else {
            return Dictionary(uniqueKeysWithValues: Title.all.map { ($0, available.height) })
        }
        let gaps = Self.spacing * CGFloat(Title.all.count - 1)
        let shares = ListFit.share(
            Double(available.height - gaps), among: Title.all.map { Double(needs[$0] ?? .infinity) }
        )
        return Dictionary(
            uniqueKeysWithValues: zip(Title.all, shares.map { CGFloat($0) }))
    }

    @ViewBuilder private func sections(_ budgets: [String: CGFloat]) -> some View {
        // Relative times ("ends in 2h 10m") move on every minute between refreshes.
        TimelineView(.everyMinute) { context in
            FittedSection(
                title: Title.silences, empty: "No active silences", items: home.silences,
                available: budgets[Title.silences] ?? available.height,
                collapseRequest: collapseRequest
            ) { silence in
                SilenceRow(silence: silence, now: context.date)
            }
        }
        FittedSection(
            title: Title.noisiest, empty: "Nothing fired twice", items: home.noisiest,
            available: budgets[Title.noisiest] ?? available.height,
            collapseRequest: collapseRequest
        ) { noisy in
            OccurrenceRow(occurrence: noisy.occurrence, open: open) {
                Text(noisy.events.formatted())
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("\(noisy.events) times fired, reopened or resent in 24 hours")
            }
        }
        TimelineView(.everyMinute) { context in
            FittedSection(
                title: Title.longest, empty: "Nothing is firing", items: home.longestFiring,
                available: budgets[Title.longest] ?? available.height,
                collapseRequest: collapseRequest
            ) { occurrence in
                OccurrenceRow(occurrence: occurrence, open: open) {
                    Text(
                        "for "
                            + shortDuration(
                                context.date.timeIntervalSince(occurrence.alert.startsAt))
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SilenceRow: View {
    let silence: Silence
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(silence.summary)
                    .lineLimit(1)
                Text(silence.instance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("ends in " + shortDuration(silence.endsAt.timeIntervalSince(now)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(
            "By \(silence.createdBy)" + (silence.comment.isEmpty ? "" : ": \(silence.comment)"))
    }
}

/// An occurrence's title and where it fires, with something trailing; opens it.
private struct OccurrenceRow<Trailing: View>: View {
    let occurrence: Occurrence
    let open: (Occurrence) -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        Button {
            open(occurrence)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: occurrence.alert.severity.symbolName)
                    .foregroundStyle(occurrence.alert.severity.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(occurrence.alert.title)
                        .lineLimit(1)
                    Text("\(occurrence.channel.instance) · #\(occurrence.channel.slug)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                trailing
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityHint("Opens the alert in its channel")
    }
}

/// What a tile's delivery capsule opens: alerts Alertmanager sends that never reached
/// Achtung, and ones Achtung still shows firing that Alertmanager no longer has.
struct DeliveryProblems: View {
    let delivery: Delivery
    let open: (Occurrence) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !delivery.missingInAchtung.isEmpty {
                Text("Missing in Achtung")
                    .font(.headline)
                Text("Firing in Alertmanager for over 10 minutes, never delivered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(delivery.missingInAchtung) { missing in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: missing.severity.symbolName)
                            .foregroundStyle(missing.severity.color)
                        Text(missing.title)
                        Spacer(minLength: 8)
                        Text("since " + timeOrDate(missing.startsAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !delivery.staleInAchtung.isEmpty {
                Text("Stale in Achtung")
                    .font(.headline)
                Text("Still firing here, gone from Alertmanager: a resolve that never came.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(delivery.staleInAchtung) { occurrence in
                    OccurrenceRow(occurrence: occurrence, open: open) { EmptyView() }
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
