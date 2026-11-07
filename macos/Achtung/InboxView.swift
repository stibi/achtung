import AchtungDomain
import SwiftUI

/// Three columns: channels, the selected channel's alerts, and the selected alert.
struct InboxView: View {
    let channels: [Channel]

    @State private var selectedChannelName: String?
    @State private var selectedSourceKey: String?

    private var selectedChannel: Channel? {
        channels.first { $0.name == selectedChannelName }
    }

    private var selectedAlert: IncomingAlert? {
        selectedChannel?.alerts.first { $0.sourceKey == selectedSourceKey }
    }

    var body: some View {
        NavigationSplitView {
            List(channels, id: \.name, selection: $selectedChannelName) { channel in
                Text(channel.name)
            }
            .navigationTitle("Channels")
        } content: {
            if let channel = selectedChannel {
                List(channel.alerts, id: \.sourceKey, selection: $selectedSourceKey) { alert in
                    AlertRow(alert: alert)
                }
                .navigationTitle(channel.name)
            } else {
                ContentUnavailableView("Select a channel", systemImage: "tray")
            }
        } detail: {
            if let alert = selectedAlert {
                AlertDetailView(alert: alert)
            } else {
                ContentUnavailableView("Select an alert", systemImage: "bell")
            }
        }
        .onChange(of: selectedChannelName) {
            selectedSourceKey = nil
        }
    }
}

private struct AlertRow: View {
    let alert: IncomingAlert

    var body: some View {
        VStack(alignment: .leading) {
            Text(alert.title)
            Text(alert.severity.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
