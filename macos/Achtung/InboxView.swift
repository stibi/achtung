import AchtungDomain
import AppKit
import SwiftUI

/// Live and the channels in the sidebar (`InboxSidebar`). Live is one stream of every
/// channel's occurrences, each with all its details; a channel is a list with a detail pane.
///
/// There is no server push yet, so the inbox refreshes every 30 seconds and right away
/// whenever the app becomes active.
struct InboxView: View {
    private static let refreshInterval = Duration.seconds(30)

    @State private var model: InboxModel
    @State private var selectedScope: OccurrenceScope? = .allChannels
    @State private var selectedID: Int?
    /// A channel just opened whose first unread occurrence is still to be selected, after
    /// its first refresh.
    @State private var selectFirstUnreadIn: OccurrenceScope?

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
            InboxSidebar(model: model, selection: $selectedScope)
        } detail: {
            content
        }
        // A channel that moved to another instance (ADR 0006) has a new identity; leave the
        // old one for Live rather than asking the server for it every refresh.
        .onChange(of: model.channels) {
            if case .channel(let id) = selectedScope,
                !model.channels.contains(where: { $0.id == id })
            {
                selectedScope = .allChannels
            }
        }
        // Opening a channel selects its first unread occurrence, newest change first, once
        // the first refresh has brought its list up to date (a cached one may be stale).
        .onChange(of: selectedScope) {
            selectedID = nil
            if case .channel = selectedScope {
                selectFirstUnreadIn = selectedScope
            }
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
                if !Task.isCancelled {
                    selectFirstUnread()
                }
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

    private func selectFirstUnread() {
        guard let scope = selectFirstUnreadIn, scope == selectedScope,
            let list = model.lists[scope]
        else { return }
        selectedID = model.readState.firstUnread(in: list.occurrences)?.id
        selectFirstUnreadIn = nil
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
            case .channel(let channel):
                // HSplitView sizes its panes to their ideal height unless told to fill.
                HSplitView {
                    // A fixed width; summaries wrap rather than get cut off.
                    channelList(.channel(channel))
                        .frame(minWidth: 380, idealWidth: 380, maxWidth: 380, maxHeight: .infinity)
                    occurrenceDetail
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("#\(channel.slug)")
                .navigationSubtitle(channel.instance)
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
                markRead: { model.markRead($0) },
                silence: { await model.silence($0, for: $1) })
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
                detailProblem: model.detailProblem,
                silence: { await model.silence($0, for: $1) })
        } else {
            ContentUnavailableView("Select an alert", systemImage: "bell")
        }
    }
}
