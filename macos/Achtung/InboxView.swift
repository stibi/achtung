import AchtungDomain
import AppKit
import SwiftUI

/// A sidebar with Live and the channels. Live is one stream of full alerts; a channel is a
/// list with a detail pane.
struct InboxView: View {
    @State var inbox: Inbox

    @State private var sidebarSelection: SidebarItem? = .live
    @State private var selectedID: OccurrenceID?

    private var selectedEntry: InboxEntry? {
        inbox.entries.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .badge(inbox.unreadCount)
                    .tag(SidebarItem.live)
                Section("Channels") {
                    ForEach(inbox.channels, id: \.self) { channel in
                        Label(channel, systemImage: "number")
                            .badge(inbox.unreadCount(in: channel))
                            .tag(SidebarItem.channel(channel))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch sidebarSelection {
            case .live:
                LiveView(inbox: inbox) { inbox.markRead($0) }
                    .navigationTitle("Live")
            case .channel(let channel):
                HSplitView {
                    AlertList(
                        entries: inbox.entries(in: channel), inbox: inbox, selection: $selectedID
                    )
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 480)
                    alertDetail
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
                .navigationTitle("#\(channel)")
            case nil:
                ContentUnavailableView("Select a channel", systemImage: "tray")
            }
        }
        .onChange(of: sidebarSelection) {
            selectedID = nil
        }
        .onChange(of: selectedID) {
            if let selectedID {
                inbox.markRead(selectedID)
            }
        }
        // Whatever is on screen when the user leaves counts as seen; anything received
        // after that shows up above the "new" divider when they come back.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) { _ in
            inbox.markSeen(at: .now)
        }
        .task {
            await SampleData.feed { alert, channel in
                inbox.receive(alert, in: channel, at: .now)
            }
        }
    }

    @ViewBuilder private var alertDetail: some View {
        if let entry = selectedEntry {
            AlertDetailView(alert: entry.alert)
        } else {
            ContentUnavailableView("Select an alert", systemImage: "bell")
        }
    }
}

private enum SidebarItem: Hashable {
    case live
    case channel(String)
}
