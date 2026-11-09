import AchtungDomain
import SwiftUI

/// One alert in an Alertmanager's detail: its title and how long it has fired, the summary,
/// a few labels that say where (the rest in the help), how it's silenced, and a hint when
/// Achtung never got it. With an occurrence in Achtung, clicking it opens that. Its context
/// menu adds its alertname to the ignored alert names, which takes it off Home.
struct AlertmanagerAlertRow: View {
    let alert: AlertmanagerAlert
    let now: Date
    let actions: AlertRowActions

    var body: some View {
        row
            .contextMenu {
                if let name = alert.alertname {
                    Button("Ignore Alerts Named “\(name)”", systemImage: "eye.slash") {
                        actions.ignore(name)
                    }
                }
            }
    }

    @ViewBuilder private var row: some View {
        if let id = alert.occurrenceID {
            Button {
                actions.open(id)
            } label: {
                content
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityHint("Opens the alert in its channel")
        } else {
            content
                .contentShape(.rect)
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: alert.severity.symbolName)
                .foregroundStyle(alert.severity.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(alert.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("since " + shortDuration(now.timeIntervalSince(alert.startsAt)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Started " + timeOrDate(alert.startsAt))
                }
                if let summary = alert.summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                details
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Key labels, the silence, and whether Achtung has it, on one quiet line.
    private var details: some View {
        HStack(spacing: 10) {
            let labels = alert.keyLabels.map { "\($0.name)=\($0.value)" }
            if !labels.isEmpty {
                Text(labels.joined(separator: "  "))
                    .lineLimit(1)
                    .help(
                        alert.otherLabels.map { "\($0.name)=\($0.value)" }.joined(separator: "\n"))
            }
            if case .silenced(let until) = alert.state {
                Label(
                    until.map { "until \(timeOrDate($0))" } ?? "end unknown",
                    systemImage: "bell.slash")
            }
            if alert.occurrenceID == nil {
                Text("Not in Achtung")
                    .help("Alertmanager has this alert, but Achtung never received it")
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}
