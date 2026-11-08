import AchtungDomain
import SwiftUI

/// One occurrence in a list. Unread ones carry a dot and a bold title; read ones are
/// grayed out. The severity icon keeps its color while the alert fires, read or not. The
/// time is the last event (fired, resolved, reopened), which is what the list is sorted by.
struct AlertRow: View {
    let occurrence: Occurrence
    let isRead: Bool

    private var alert: IncomingAlert { occurrence.alert }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            Image(systemName: alert.severity.symbolName)
                .font(.title2)
                .foregroundStyle(alert.isFiring ? alert.severity.color : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
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
