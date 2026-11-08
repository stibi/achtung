import AchtungDomain
import SwiftUI

/// The last 24 hours beside the Live stream, now at the top: where alerts fired (filled
/// markers), resolved (hollow ones) and were last resent (a small circular arrow), with a
/// bar for how long each fired. Unread ones are ringed, read ones dimmed. Markers close
/// together become one with a count. Clicking one shows its card in the stream; for a
/// cluster, its newest.
struct LiveTimeline: View {
    static let width: CGFloat = 200

    let occurrences: [Occurrence]
    let readState: ReadState
    let select: (Occurrence) -> Void

    var body: some View {
        // Redrawn every minute, so the 24 hours move with the clock.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let timeline = Timeline(
                occurrences: occurrences, readState: readState,
                window: TimelineWindow(endingAt: context.date))
            VStack(alignment: .leading, spacing: 10) {
                Text("Last 24 hours")
                    .font(.headline)
                GeometryReader { geometry in
                    TimelinePlot(timeline: timeline, size: geometry.size, select: select)
                }
            }
            .padding(14)
        }
    }
}

private struct TimelinePlot: View {
    /// Markers closer than this, in points, become one cluster.
    private static let clusterGap: CGFloat = 18
    private static let inset: CGFloat = 8
    private static let labelWidth: CGFloat = 40
    private static let axisX: CGFloat = labelWidth + 12
    /// Room for a marker's label, so a long title ends in "…" inside the card.
    static let markLabelWidth: CGFloat = LiveTimeline.width - 28 - axisX - 20

    let timeline: Timeline
    let size: CGSize
    let select: (Occurrence) -> Void

    private var plotHeight: CGFloat { max(size.height - 2 * Self.inset, 1) }

    private func y(_ position: Double) -> CGFloat {
        Self.inset + position * plotHeight
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: plotHeight)
                .offset(x: Self.axisX, y: Self.inset)
            ticks
            // Firing times merged per severity, least severe first so critical is on top.
            ForEach(timeline.bars) { bar in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(bar.severity.color.opacity(bar.isOpen ? 0.6 : 0.35))
                    .frame(width: 3, height: max(y(bar.bottom) - y(bar.top), 2))
                    .offset(x: Self.axisX - 1, y: y(bar.top))
            }
            now
            ForEach(timeline.clusters(gap: Self.clusterGap / plotHeight)) { cluster in
                Button {
                    select(cluster.newest.occurrence)
                } label: {
                    ClusterMark(cluster: cluster)
                }
                .buttonStyle(.plain)
                .offset(
                    x: Self.axisX - ClusterMark.height / 2,
                    y: y(cluster.position) - ClusterMark.height / 2)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The top edge, marked: everything below happened before now.
    private var now: some View {
        HStack(spacing: 4) {
            Text("now")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: Self.labelWidth, alignment: .trailing)
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 24, height: 1.5)
        }
        .frame(height: 12)
        .offset(y: y(0) - 6)
        .help("Now: \(timeline.window.end.formatted(date: .omitted, time: .shortened))")
    }

    private var ticks: some View {
        // The newest tick would sit on the "now" label; skip it when it's that close.
        let ticks = timeline.window.ticks(every: 3, calendar: .current)
            .filter { timeline.window.clampedPosition(of: $0) > 0.04 }
        return ForEach(ticks, id: \.self) { tick in
            HStack(spacing: 4) {
                Text(tick.formatted(.dateTime.hour()))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                Rectangle()
                    .fill(.separator)
                    .frame(width: 6, height: 1)
            }
            .frame(height: 12)
            .offset(y: y(timeline.window.clampedPosition(of: tick)) - 6)
        }
    }
}

/// One marker, or a cluster of them with its count, with a short label to its right.
private struct ClusterMark: View {
    static let height: CGFloat = 18

    let cluster: TimelineCluster

    private var color: Color { cluster.severity.color }
    private var single: TimelineMarker? { cluster.count == 1 ? cluster.newest : nil }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if cluster.hasUnread {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: Self.height, height: Self.height)
                }
                if let single, single.kind == .resent {
                    // Calm, even on a critical alert: the ring shows whether it's unread.
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                } else if let single {
                    Circle()
                        .fill(single.kind == .fired ? color : .clear)
                        .strokeBorder(color, lineWidth: 2)
                        .frame(width: 10, height: 10)
                } else {
                    Text(cluster.count.formatted())
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(color, in: Circle())
                }
            }
            .frame(width: Self.height, height: Self.height)
            Text(single?.occurrence.alert.title ?? alerts)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(cluster.hasUnread ? .primary : .secondary)
                .frame(maxWidth: TimelinePlot.markLabelWidth, alignment: .leading)
        }
        .opacity(cluster.hasUnread ? 1 : 0.55)
        .contentShape(.rect)
        .pointerStyle(.link)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Shows the alert in the stream")
    }

    /// "Alert X, onprem · #infra, fired 14:05", or "3 alerts, newest: …".
    private var accessibilityText: String {
        let newest = cluster.newest
        let what = newest.kind.title.lowercased()
        let description =
            "\(newest.occurrence.alert.title), \(newest.occurrence.channel.instance) · "
            + "#\(newest.occurrence.channel.slug), \(what) "
            + newest.date.formatted(date: .omitted, time: .shortened)
        return cluster.count == 1 ? description : "\(alerts), newest: \(description)"
    }

    /// "3 alerts", or "1 alert" for one that fired and resolved close together.
    private var alerts: String {
        cluster.alertCount == 1 ? "1 alert" : "\(cluster.alertCount) alerts"
    }

    /// Up to five of its events: title, where it came from, what happened and when.
    private var help: String {
        let lines = cluster.markers.prefix(5).map { marker in
            let occurrence = marker.occurrence
            let what = marker.kind.title
            return "\(occurrence.alert.title)\n\(occurrence.channel.instance) · "
                + "#\(occurrence.channel.slug)\n\(what) "
                + marker.date.formatted(date: .abbreviated, time: .shortened)
        }
        let more = cluster.count > 5 ? "\n\n…and \(cluster.count - 5) more" : ""
        return lines.joined(separator: "\n\n") + more
    }
}

extension TimelineMarker.Kind {
    fileprivate var title: String {
        switch self {
        case .fired: "Fired"
        case .resolved: "Resolved"
        case .resent: "Resent"
        }
    }
}
