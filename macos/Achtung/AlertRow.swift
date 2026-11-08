import AchtungDomain
import SwiftUI

/// One occurrence in a list. Unread ones carry a dot (a circular arrow when resent) and a
/// bold title; read ones are grayed out. The severity icon keeps its color while the alert
/// fires, read or not. The time is the last event (fired, resolved, reopened, resent),
/// which is what the list is sorted by.
struct AlertRow: View {
    let occurrence: Occurrence
    let isRead: Bool

    private var alert: IncomingAlert { occurrence.alert }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            UnreadMark(occurrence: occurrence, isRead: isRead)
                .padding(.top, 7)
            Image(systemName: alert.severity.symbolName)
                .font(.title2)
                .foregroundStyle(alert.isFiring ? alert.severity.color : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    SilenceState(occurrence: occurrence) { isSilenced in
                        if isSilenced {
                            Image(systemName: "bell.slash")
                                .foregroundStyle(.secondary)
                                .help("Silenced in Alertmanager")
                        }
                    }
                    Text(alert.title)
                        .font(.headline.weight(isRead ? .regular : .bold))
                        .foregroundStyle(isRead ? .secondary : .primary)
                    Spacer()
                    RelativeTime(date: occurrence.lastEventAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let summary = alert.summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(isRead ? .tertiary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !alert.isFiring {
                    StatusPill(alert: alert)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    VStack {
        AlertRow(occurrence: SampleData.occurrences[0], isRead: false)
        AlertRow(occurrence: SampleData.occurrences[1], isRead: true)
    }
    .padding()
}
