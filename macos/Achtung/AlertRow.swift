import AchtungDomain
import SwiftUI

/// One alert in a list. Unread alerts carry a dot and a bold title; read ones are grayed
/// out. The severity icon keeps its color while the alert fires, read or not.
struct AlertRow: View {
    let entry: InboxEntry
    let isRead: Bool

    private var alert: IncomingAlert { entry.alert }

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
                    RelativeTime(date: alert.startsAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let summary = alert.summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(isRead ? .tertiary : .secondary)
                        .lineLimit(2)
                }
                if !alert.isFiring {
                    StatusPill(alert: alert)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
