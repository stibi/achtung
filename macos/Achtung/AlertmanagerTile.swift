import AchtungDomain
import SwiftUI

/// One Alertmanager on Home, as it last read: its open alerts as a big number coloured by
/// the worst severity (a calm "All quiet" at zero), a severity bar and breakdown, what's
/// silenced or inhibited, whether its Watchdog fires, and any delivery problem between it
/// and Achtung. An unreachable one keeps its last numbers, dimmed.
struct AlertmanagerTile: View {
    let overview: AlertmanagerOverview
    let open: (Occurrence) -> Void
    /// Opens the Alertmanager's detail: its alerts by severity.
    let show: () -> Void

    @State private var showsDelivery = false

    private var isUnreachable: Bool { !overview.isReachable }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                    .help(statusHelp)
                Text(overview.instance)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let read = overview.lastRead {
                    WatchdogMark(fires: read.watchdogFires)
                }
            }
            if let read = overview.lastRead {
                readDetails(read)
                    .opacity(isUnreachable ? 0.5 : 1)
            } else {
                Text("Not read yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if case .unreachable(let error, _) = overview.status {
                Label(error, systemImage: "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(16)
        // As tall as the tallest in its row, so a row of tiles lines up.
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        // The whole tile opens the detail; the delivery capsule, a button of its own,
        // still opens its popover.
        .contentShape(.rect(cornerRadius: 14))
        .onTapGesture(perform: show)
        .pointerStyle(.link)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        // VoiceOver's press, as well as clicking.
        .accessibilityAction { show() }
        // VoiceOver may step into the tile rather than press it; the actions menu has this.
        .accessibilityAction(named: "Show alerts") { show() }
        .accessibilityHint("Shows its alerts")
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private func readDetails(_ read: AlertmanagerOverview.Read) -> some View {
        if read.open.total == 0 {
            Label("All quiet", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.vertical, 6)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(read.open.total.formatted())
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(totalColor(read.open.emphasis))
                Text("open")
                    .foregroundStyle(.secondary)
            }
            SeverityBar(counts: read.open)
            if let breakdown = read.open.breakdown {
                Text(breakdown)
                    .font(.caption)
            }
        }
        if let quieted = read.quieted {
            Text(quieted)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let summary = read.delivery.summary {
            Button {
                showsDelivery = true
            } label: {
                Label(summary, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Delivery between this Alertmanager and Achtung broke: see which alerts")
            .popover(isPresented: $showsDelivery, arrowEdge: .bottom) {
                DeliveryProblems(delivery: read.delivery) { occurrence in
                    showsDelivery = false
                    open(occurrence)
                }
            }
        }
    }

    private func totalColor(_ emphasis: OpenAlertCounts.Emphasis) -> Color {
        switch emphasis {
        case .critical: Severity.critical.color
        case .warning: Severity.warning.color
        case .neutral, .allQuiet: .primary
        }
    }

    private var statusColor: Color {
        switch overview.status {
        case .reachable: .green
        case .unreachable(_, .some): .red
        case .unreachable(_, nil): .gray
        }
    }

    private var lastReadText: String {
        guard let read = overview.lastRead else { return "never read" }
        return "last read \(timeOrDate(read.checkedAt))"
    }

    private var statusHelp: String {
        switch overview.status {
        case .reachable: "Reachable, \(lastReadText)"
        case .unreachable(let error, _): "Unreachable: \(error); \(lastReadText)"
        }
    }

    /// "cdx, 15 open, 3 critical · 8 warning, 4 silenced, watchdog firing, 2 missing".
    private var accessibilityText: String {
        var parts = [overview.instance]
        if isUnreachable {
            parts.append("unreachable, \(lastReadText)")
        }
        if let read = overview.lastRead {
            parts.append(read.open.total == 0 ? "all quiet" : "\(read.open.total) open")
            parts += [read.open.breakdown, read.quieted, read.delivery.summary].compactMap(\.self)
            parts.append(read.watchdogFires ? "watchdog firing" : "no watchdog")
        }
        return parts.joined(separator: ", ")
    }
}

/// The open alerts by severity, as one thin bar, critical first.
private struct SeverityBar: View {
    let counts: OpenAlertCounts

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(counts.bySeverity, id: \.severity) { part in
                    Rectangle()
                        .fill(part.severity.color)
                        .frame(
                            width: max(
                                geometry.size.width * CGFloat(part.count)
                                    / CGFloat(max(counts.total, 1)) - 2, 3))
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Green while the Watchdog fires (the alerting pipeline works), amber when it's absent.
private struct WatchdogMark: View {
    let fires: Bool

    var body: some View {
        Image(systemName: fires ? "heart.fill" : "heart.slash.fill")
            .foregroundStyle(fires ? .green : .orange)
            .help(
                fires
                    ? "Watchdog firing: the alerting pipeline works"
                    : "No watchdog: the alerting pipeline may be broken")
    }
}
