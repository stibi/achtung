import AchtungDomain
import SwiftUI

/// Home's three lists under the tiles: silences ending soon, the noisiest alerts of the
/// last 24 hours and the longest firing. Rows with an occurrence open it in its channel.
struct HomeSections: View {
    let home: Home
    let open: (Occurrence) -> Void

    var body: some View {
        // Side by side when there's room, stacked when not.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { sections }
            VStack(alignment: .leading, spacing: 16) { sections }
        }
    }

    @ViewBuilder private var sections: some View {
        // Relative times ("ends in 2h 10m") move on every minute between refreshes.
        TimelineView(.everyMinute) { context in
            HomeSection(title: "Silences ending soon", empty: "No active silences") {
                ForEach(home.silences) { silence in
                    SilenceRow(silence: silence, now: context.date)
                }
            }
        }
        HomeSection(title: "Noisiest, 24h", empty: "Nothing fired twice") {
            ForEach(home.noisiest) { noisy in
                OccurrenceRow(occurrence: noisy.occurrence, open: open) {
                    Text(noisy.events.formatted())
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("\(noisy.events) times fired, reopened or resent in 24 hours")
                }
            }
        }
        TimelineView(.everyMinute) { context in
            HomeSection(title: "Longest firing", empty: "Nothing is firing") {
                ForEach(home.longestFiring) { occurrence in
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
}

/// A titled card of rows, with a quiet line when it has none.
private struct HomeSection<Rows: View>: View {
    let title: String
    let empty: String
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Group(subviews: rows) { subviews in
                if subviews.isEmpty {
                    Text(empty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(subviews) { $0 }
                    }
                }
            }
        }
        .padding(16)
        // An ideal width of its own, not its longest row's: `ViewThatFits` compares ideal
        // widths, and one long title would otherwise stack the sections in a wide window.
        .frame(minWidth: 260, idealWidth: 260, maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
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
