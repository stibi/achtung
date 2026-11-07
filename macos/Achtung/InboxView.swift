import AchtungDomain
import AppKit
import SwiftUI

/// Channels in the sidebar; a channel is a list of occurrences with a detail pane.
///
/// There is no server push yet, so the inbox refreshes every 30 seconds and right away
/// whenever the app becomes active.
struct InboxView: View {
    private static let refreshInterval = Duration.seconds(30)

    @State private var model: InboxModel
    @State private var selectedChannel: String?
    @State private var selectedID: Int?

    init(baseURL: URL) {
        _model = State(initialValue: InboxModel(baseURL: baseURL))
    }

    private var detailRetry: Date? {
        model.detailProblem == nil ? nil : model.lastUpdated
    }

    private var selectedOccurrence: Occurrence? {
        selectedChannel.flatMap { model.lists[$0] }?.occurrences.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
        }
        .onChange(of: model.channels) {
            if selectedChannel == nil {
                selectedChannel = model.channels.first?.slug
            }
        }
        .onChange(of: selectedChannel) {
            selectedID = nil
        }
        // Also fires when a refresh brings a newer version of the open occurrence: the user
        // is looking at it, so it stays read.
        .onChange(of: selectedOccurrence) {
            if let selectedOccurrence {
                model.markRead(selectedOccurrence)
            }
        }
        .task(id: selectedChannel) {
            while !Task.isCancelled {
                await model.refresh(selectedChannel, visiting: NSApp.isActive)
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return  // Cancelled: another channel was selected or the window closed.
                }
            }
        }
        // Reloads when the occurrence changes, and after a failed load once a refresh
        // succeeds again.
        .task(id: [selectedOccurrence, detailRetry] as [AnyHashable?]) {
            if let selectedOccurrence {
                await model.loadDetail(of: selectedOccurrence)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await model.refresh(selectedChannel, visiting: true) }
        }
        // Whatever is on screen when the user leaves counts as seen; anything that changes
        // after that shows up above the "new" divider when they come back.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) { _ in
            model.markSeen()
        }
    }

    private var sidebar: some View {
        List(selection: $selectedChannel) {
            Section("Channels") {
                ForEach(model.channels) { channel in
                    HStack {
                        Label(channel.slug, systemImage: "number")
                        Spacer()
                        if model.readState.hasNews(channel) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                                .help("Changed since you last looked")
                        }
                    }
                    .badge(channel.firing)
                    .tag(channel.slug)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            if let problem = model.problem {
                ConnectionBanner(problem: problem, lastUpdated: model.lastUpdated)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let channel = selectedChannel {
            HSplitView {
                channelList(channel)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 480)
                occurrenceDetail
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
            .navigationTitle("#\(channel)")
        } else if let problem = model.problem, model.channels.isEmpty {
            UnreachableView(problem: problem, baseURL: model.baseURL) {
                Task { await model.refresh(nil, visiting: true) }
            }
        } else if model.lastUpdated == nil {
            ProgressView("Connecting to \(model.baseURL.absoluteString)…")
        } else {
            ContentUnavailableView(
                "No channels yet", systemImage: "tray",
                description: Text("A channel appears when its first alert arrives."))
        }
    }

    @ViewBuilder private func channelList(_ channel: String) -> some View {
        if let list = model.lists[channel] {
            AlertList(
                occurrences: list.occurrences, readState: model.readState,
                hasOlder: model.hasOlder(in: channel),
                lastUpdated: model.lastUpdated,
                loadOlder: { await model.loadOlder(in: channel) },
                selection: $selectedID)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var occurrenceDetail: some View {
        if let occurrence = selectedOccurrence {
            AlertDetailView(
                occurrence: occurrence,
                detail: model.detail?.occurrence.id == occurrence.id ? model.detail : nil,
                detailProblem: model.detailProblem)
        } else {
            ContentUnavailableView("Select an alert", systemImage: "bell")
        }
    }
}
