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

/// "Resent 14:05" in the alert header: the source repeated this still-firing alert, which
/// made it unread again. The accent colour, like the unread dot it replaces.
struct ResentPill: View {
    let date: Date

    var body: some View {
        Label("Resent \(timeOrDate(date))", systemImage: "arrow.clockwise")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .help(Self.explanation)
    }

    static let explanation =
        "Alertmanager sent this alert again while it still fires. It isn't new: it counts as "
        + "unread again because it's still not fixed."
}

/// Where a row or card shows that it's unread: a dot for something new, a circular arrow
/// for a resend of an alert that was already there. Nothing once read.
struct UnreadMark: View {
    let occurrence: Occurrence
    let isRead: Bool

    var body: some View {
        if isRead {
            Color.clear.frame(width: 8, height: 8)
        } else if occurrence.isResent {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 8, height: 8)
                .help(ResentPill.explanation)
                .accessibilityLabel("Unread, resent")
        } else {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Unread")
        }
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

/// A list with read alerts hidden and nothing unread. Live's shows the krysa on a coffee
/// break above it (`CoffeeBreak`), as a small reward.
struct CaughtUpView: View {
    var coffeeBreak = false
    let showRead: () -> Void

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 18) {
                if coffeeBreak {
                    CoffeeBreak()
                }
                Label {
                    Text("All caught up")
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                }
            }
        } description: {
            Text("New alerts and resends show up here.")
        } actions: {
            Button("Show Read Alerts", action: showRead)
        }
    }
}

/// A list's title with the switch that hides its read alerts, so it shows only new ones
/// and resends. It stands in the toolbar in place of the window title, on the list's line.
struct ListHeader: View {
    let title: String
    let subtitle: String?
    @Binding var unreadOnly: Bool

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            // A toolbar hides a toggle's own label, so it's spelled out beside the switch.
            HStack(spacing: 6) {
                Text("Unread only")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    // The switch carries the same label for VoiceOver.
                    .accessibilityHidden(true)
                Toggle("Unread only", isOn: $unreadOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .help("Show only new alerts and resends")
        }
        .padding(.horizontal, 8)
    }
}

/// The time alone when `date` is today, else the date too.
func timeOrDate(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(date: .abbreviated, time: .shortened)
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

extension View {
    /// A card set into a pane, like the alert metadata panel and the Live timeline: rounded,
    /// on a material, with a hairline border and a very soft shadow. Content is clipped to
    /// the card.
    func paneCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return
            self
            .background(.regularMaterial, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}
