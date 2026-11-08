import AchtungDomain
import AppKit
import SwiftUI

/// Live and the channels in the sidebar. Live is one stream of every channel's
/// occurrences, each with all its details; a channel is a list with a detail pane.
///
/// There is no server push yet, so the inbox refreshes every 30 seconds and right away
/// whenever the app becomes active.
struct InboxView: View {
    private static let refreshInterval = Duration.seconds(30)

    @State private var model: InboxModel
    @State private var selectedScope: OccurrenceScope? = .allChannels
    @State private var selectedID: Int?

    init(baseURL: URL) {
        _model = State(initialValue: InboxModel(baseURL: baseURL))
    }

    private var detailRetry: Date? {
        model.detailProblem == nil ? nil : model.lastUpdated
    }

    private var selectedOccurrence: Occurrence? {
        selectedScope.flatMap { model.lists[$0] }?.occurrences.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
        }
        .onChange(of: selectedScope) {
            selectedID = nil
        }
        // Also fires when a refresh brings a newer version of the open occurrence: the user
        // is looking at it, so it stays read.
        .onChange(of: selectedOccurrence) {
            if let selectedOccurrence {
                model.markRead(selectedOccurrence)
            }
        }
        .task(id: selectedScope) {
            while !Task.isCancelled {
                await model.refresh(selectedScope, visiting: NSApp.isActive)
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return  // Cancelled: another list was selected or the window closed.
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
            Task { await model.refresh(selectedScope, visiting: true) }
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
        List(selection: $selectedScope) {
            sidebarRow(
                "Live", systemImage: "dot.radiowaves.left.and.right",
                firing: model.channels.reduce(0) { $0 + $1.firing },
                hasNews: model.channels.contains { model.readState.hasNews($0) }
            )
            .tag(OccurrenceScope.allChannels)
            Section("Channels") {
                ForEach(model.channels) { channel in
                    sidebarRow(
                        channel.slug, systemImage: "number", firing: channel.firing,
                        hasNews: model.readState.hasNews(channel)
                    )
                    .tag(OccurrenceScope.channel(channel.slug))
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

    /// Badge: what is firing. Dot: something happened since the user last looked.
    private func sidebarRow(_ title: String, systemImage: String, firing: Int, hasNews: Bool)
        -> some View
    {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if hasNews {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .help("Changed since you last looked")
            }
        }
        .badge(firing)
    }

    @ViewBuilder private var content: some View {
        if let problem = model.problem, model.lastUpdated == nil {
            UnreachableView(problem: problem, baseURL: model.baseURL) {
                Task { await model.refresh(selectedScope, visiting: true) }
            }
        } else if model.lastUpdated == nil {
            ProgressView("Connecting to \(model.baseURL.absoluteString)…")
        } else {
            switch selectedScope {
            case .allChannels:
                liveStream
                    .navigationTitle("Live")
            case .channel(let slug):
                // HSplitView sizes its panes to their ideal height unless told to fill.
                HSplitView {
                    channelList(.channel(slug))
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 480, maxHeight: .infinity)
                    occurrenceDetail
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("#\(slug)")
            case nil:
                ContentUnavailableView("Select a channel", systemImage: "tray")
            }
        }
    }

    @ViewBuilder private var liveStream: some View {
        if let list = model.lists[.allChannels] {
            LiveView(
                occurrences: list.occurrences, readState: model.readState,
                hasOlder: model.hasOlder(in: .allChannels), lastUpdated: model.lastUpdated,
                loadOlder: { await model.loadOlder(in: .allChannels) },
                markRead: { model.markRead($0) })
        } else {
            loading(.allChannels)
        }
    }

    @ViewBuilder private func channelList(_ scope: OccurrenceScope) -> some View {
        if let list = model.lists[scope] {
            AlertList(
                occurrences: list.occurrences, readState: model.readState,
                hasOlder: model.hasOlder(in: scope),
                lastUpdated: model.lastUpdated,
                loadOlder: { await model.loadOlder(in: scope) },
                selection: $selectedID)
        } else {
            loading(scope)
        }
    }

    /// Until a list's first page arrives. If loading it failed, say why instead of
    /// spinning; the next refresh retries.
    @ViewBuilder private func loading(_ scope: OccurrenceScope) -> some View {
        if let problem = model.problem {
            UnreachableView(problem: problem, baseURL: model.baseURL) {
                Task { await model.refresh(scope, visiting: true) }
            }
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
