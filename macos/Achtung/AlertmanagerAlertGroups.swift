import AchtungDomain
import SwiftUI

/// What an alert row in an Alertmanager's detail can do.
struct AlertRowActions {
    /// Shows the alert's occurrence in its channel, by the occurrence's id.
    let open: (Int) -> Void
    /// Adds an alertname to the ignored alert names.
    let ignore: (String) -> Void
    /// The alerts picked for silencing, by fingerprint.
    let selection: Binding<Set<String>>
}

/// The active alerts by severity, or "All quiet", then the silenced and inhibited ones.
struct AlertGroups: View {
    let alerts: AlertmanagerAlerts
    let now: Date
    let actions: AlertRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if case .unreachable(let error, let lastRead) = alerts.status {
                Label(
                    lastRead.map { "\(error). Showing the read from \(timeOrDate($0))." }
                        ?? "\(error). It has never been read.",
                    systemImage: "bolt.horizontal.circle"
                )
                .foregroundStyle(.red)
            }
            let groups = alerts.activeBySeverity
            if groups.isEmpty, alerts.checkedAt != nil {
                Label("All quiet", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
            }
            ForEach(groups, id: \.severity) { group in
                VStack(alignment: .leading, spacing: 6) {
                    GroupHeader(
                        title: group.severity.groupTitle, count: group.alerts.count,
                        color: group.severity.color, fingerprints: group.alerts.map(\.fingerprint),
                        selection: actions.selection)
                    AlertCard(alerts: group.alerts, now: now, actions: actions)
                }
            }
            FoldedGroup(title: "Silenced", alerts: alerts.silenced, now: now, actions: actions)
            FoldedGroup(title: "Inhibited", alerts: alerts.inhibited, now: now, actions: actions)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GroupHeader: View {
    let title: String
    let count: Int
    let color: Color
    /// The group's alerts, which its checkbox selects all of, or none.
    let fingerprints: [String]
    @Binding var selection: Set<String>

    var body: some View {
        HStack(spacing: 8) {
            SelectAllBox(fingerprints: fingerprints, selection: $selection, title: title)
            // The title and its count read as one.
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(color)
                Text(count.formatted())
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(color, in: Capsule())
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A checkbox for a group: checked when all of it is selected, a dash when some are.
private struct SelectAllBox: View {
    let fingerprints: [String]
    @Binding var selection: Set<String>
    let title: String

    private var selected: Int { fingerprints.filter(selection.contains).count }

    var body: some View {
        Button {
            if selected == fingerprints.count {
                selection.subtract(fingerprints)
            } else {
                selection.formUnion(fingerprints)
            }
        } label: {
            Image(
                systemName: selected == 0
                    ? "square"
                    : selected == fingerprints.count
                        ? "checkmark.square.fill" : "minus.square.fill"
            )
            .foregroundStyle(selected == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.borderless)
        .help("Select every \(title.lowercased()) alert for silencing")
        .accessibilityLabel("Select all \(title)")
        .accessibilityValue(
            selected == 0
                ? "none selected"
                : selected == fingerprints.count ? "all selected" : "some selected")
    }
}

/// A group's alerts on one card, divided.
private struct AlertCard: View {
    let alerts: [AlertmanagerAlert]
    let now: Date
    let actions: AlertRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                if index > 0 {
                    Divider()
                }
                AlertmanagerAlertRow(alert: alert, now: now, actions: actions)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

/// "Silenced (4)", folded until opened; nothing when there are none.
private struct FoldedGroup: View {
    let title: String
    let alerts: [AlertmanagerAlert]
    let now: Date
    let actions: AlertRowActions

    var body: some View {
        if !alerts.isEmpty {
            // Folded until opened, as a DisclosureGroup starts.
            DisclosureGroup {
                AlertCard(alerts: alerts, now: now, actions: actions)
                    .padding(.top, 6)
            } label: {
                Text("\(title) (\(alerts.count))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Severity {
    /// A group's title in an Alertmanager's detail.
    fileprivate var groupTitle: String {
        switch self {
        case .critical: "Critical"
        case .warning: "Warning"
        case .info: "Info"
        case .unknown: "Other"
        }
    }
}
