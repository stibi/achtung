import AchtungDomain
import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        case .unknown: .gray
        }
    }

    var symbolName: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

extension AlertLink.Kind {
    var symbolName: String {
        switch self {
        case .source: "arrow.up.forward.square"
        case .runbook: "book"
        case .dashboard: "chart.xyaxis.line"
        }
    }
}

/// "Firing" in the severity's color or "Resolved" in green, as a small capsule. Red stays
/// reserved for critical.
struct StatusPill: View {
    let alert: IncomingAlert

    var body: some View {
        Text(alert.isFiring ? "Firing" : "Resolved")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        alert.isFiring ? alert.severity.color : .green
    }
}

/// Marks where the user left off: everything above it arrived since then.
struct NewDivider: View {
    let seenUntil: Date

    var body: some View {
        HStack(spacing: 8) {
            line
            Label(
                "New since \(seenUntil.formatted(date: .omitted, time: .shortened))",
                systemImage: "arrow.up"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .fixedSize()
            line
        }
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
    }

    private var line: some View {
        Rectangle().fill(Color.accentColor).frame(height: 1)
    }
}

/// Shown instead of an empty list.
struct AllClearView: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text("All clear")
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        } description: {
            Text("Nothing has arrived here yet.")
        }
    }
}

/// A relative time ("5 minutes ago") that stays current while the window is open.
struct RelativeTime: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))
        }
    }
}
