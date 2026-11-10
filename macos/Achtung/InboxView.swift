import AchtungDomain
import AppKit
import SwiftUI

/// Home, Live and the channels in the sidebar (`InboxSidebar`). Home is each Alertmanager
/// at a glance (`HomeView`); Live is one stream of every channel's occurrences, each with
/// all its details; a channel is a list with a detail pane. The app opens on Home.
///
/// There is no server push yet, so the inbox refreshes every 30 seconds (`AppModel`, with or
/// without a window), right away when a list opens, and whenever the app becomes active.
struct InboxView: View {
    let model: InboxModel
    @State var page: InboxPage? = .home
    @State var selectedID: Int?
    /// An occurrence opened from Home, selected in its channel even if neither the list's
    /// loaded pages nor the feed hold it; let go once the selection moves on.
    @State var revealed: Occurrence?
    /// Live's card the user last clicked (`LiveView.kept`), here so marking all read can
    /// let it go.
    @State private var liveKept: Int?
    /// A channel just opened whose first unread occurrence is still to be selected, after
    /// its first refresh.
    @State var selectFirstUnreadIn: OccurrenceScope?
    /// The search field's text and tokens, and the search shown, if any (`InboxSearch`).
    @State var query = SearchQuery()
    @State var activeSearch: OccurrenceSearch?

    private var detailRetry: Date? {
        model.detailProblem == nil ? nil : model.lastUpdated
    }

    var selectedScope: OccurrenceScope? {
        if case .list(let scope) = page { scope } else { nil }
    }

    private var selectedOccurrence: Occurrence? {
        selectedScope.flatMap {
            model.shownOccurrences(in: $0, keeping: selectedID, revealing: revealed)
        }?
        .first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            InboxSidebar(model: model, selection: sidebarSelection)
        } detail: {
            content
        }
        .modifier(
            InboxSearch(model: model, query: $query, active: $activeSearch)
        )
        // A channel that moved to another instance (ADR 0006) has a new identity; leave the
        // old one for Live rather than asking the server for it every refresh.
        .onChange(of: model.channels) {
            if case .channel(let id) = selectedScope,
                !model.channels.contains(where: { $0.id == id })
            {
                page = .list(.allChannels)
            }
        }
        // Opening a channel selects its first unread occurrence, newest change first, once
        // the first refresh has brought its list up to date (a cached one may be stale).
        // One opened from Home is selected instead, in its own channel; anywhere else it's
        // let go.
        .onChange(of: selectedScope) {
            liveKept = nil
            if let revealed, selectedScope == .channel(revealed.channel) {
                selectedID = revealed.id
                selectFirstUnreadIn = nil
            } else {
                revealed = nil
                selectedID = nil
                if case .channel = selectedScope {
                    selectFirstUnreadIn = selectedScope
                }
            }
        }
        .onChange(of: selectedID) {
            if selectedID != revealed?.id {
                revealed = nil
            }
        }
        // Also fires when a refresh brings a newer version of the open occurrence: the user
        // is looking at it, so it stays read.
        .onChange(of: selectedOccurrence) {
            if let selectedOccurrence {
                model.markRead(selectedOccurrence)
            }
        }
        // The list on screen is what `AppModel`'s refresh brings up to date; opening one
        // refreshes it at once.
        // The one place that says which list the refresh keeps up to date: the search shown,
        // else the selected list.
        .task(id: shownScope) {
            model.activeScope = shownScope
            await model.refresh(shownScope, visiting: NSApp.isActive && activeSearch == nil)
            if !Task.isCancelled, activeSearch == nil {
                selectFirstUnread()
            }
        }
        .onDisappear { model.activeScope = nil }
        // From a notification or the menu bar, also when it opened this window.
        .onChange(of: model.openRequest, initial: true) { takeOpenRequest() }
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

    @ViewBuilder private var content: some View {
        if let activeSearch {
            // A result opens in its channel, which ends the search.
            SearchResults(model: model, search: activeSearch) { occurrence in
                query = SearchQuery()
                model.openRequest = .occurrence(occurrence)
            }
        } else if page == .home {
            // Home loads on its own (`HomeView`), not after the inbox's first refresh.
            HomeView(model: model) { occurrence in
                revealed = occurrence
                page = .list(.channel(occurrence.channel))
            }
        } else if let problem = model.problem, model.lastUpdated == nil {
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
                    .toolbar(removing: .title)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            ListHeader(
                                title: "Live", subtitle: nil,
                                unreadOnly: hidesRead(in: .allChannels),
                                hasUnread: model.hasUnread(in: .allChannels)
                            ) { markAllRead(in: .allChannels) }
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
            case .search:
                // The sidebar never selects a search; `activeSearch` shows one above.
                EmptyView()
            case .channel(let channel):
                // HSplitView sizes its panes to their ideal height unless told to fill.
                HSplitView {
                    // A fixed width; summaries wrap rather than get cut off.
                    channelList(channel)
                        .frame(minWidth: 380, idealWidth: 380, maxWidth: 380, maxHeight: .infinity)
                    occurrenceDetail
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("#\(channel.slug)")
                .navigationSubtitle(channel.instance)
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ListHeader(
                            title: "#\(channel.slug)", subtitle: channel.instance,
                            unreadOnly: hidesRead(in: .channel(channel)),
                            hasUnread: model.hasUnread(in: .channel(channel))
                        ) { markAllRead(in: .channel(channel)) }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            case nil:
                ContentUnavailableView("Select a channel", systemImage: "tray")
            }
        }
    }

    @ViewBuilder private var liveStream: some View {
        if let list = model.lists[.allChannels] {
            LiveView(
                occurrences: list.occurrences, firing: model.firing, readState: model.readState,
                hasOlder: model.hasOlder(in: .allChannels), lastUpdated: model.lastUpdated,
                loadOlder: { await model.loadOlder(in: .allChannels) },
                hidesRead: hidesRead(in: .allChannels), kept: $liveKept,
                markRead: { model.markRead($0) },
                silence: SilenceActions(model))
        } else {
            loading(.allChannels)
        }
    }

    /// Also lets go of the open alert, so with read alerts hidden the list empties into "All
    /// caught up" rather than keeping one that would look as if it wasn't marked.
    private func markAllRead(in scope: OccurrenceScope) {
        model.markAllRead(in: scope)
        selectedID = nil
        liveKept = nil
    }

    private func hidesRead(in scope: OccurrenceScope) -> Binding<Bool> {
        Binding {
            model.hidesRead(in: scope)
        } set: {
            model.setHidesRead($0, in: scope)
        }
    }

    @ViewBuilder private func channelList(_ channel: ChannelID) -> some View {
        let scope = OccurrenceScope.channel(channel)
        if let occurrences = model.shownOccurrences(
            in: scope, keeping: selectedID, revealing: revealed)
        {
            let hidingRead = model.hidesRead(in: scope)
            AlertList(
                occurrences: occurrences, readState: model.readState,
                // Hidden while read alerts are: the feed already brought every unread one,
                // so older pages would add nothing to show.
                hasOlder: !hidingRead && model.hasOlder(in: scope),
                lastUpdated: model.lastUpdated,
                loadOlder: { await model.loadOlder(in: scope) },
                hidesRead: hidesRead(in: scope),
                selection: $selectedID, copy: copy, silence: SilenceActions(model))
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

    /// Copies an occurrence for an agent, with its history when it's the open alert's,
    /// which has loaded it.
    private func copy(_ occurrence: Occurrence) {
        let detail = model.detail?.occurrence.id == occurrence.id ? model.detail : nil
        copyForAgent(occurrence, events: detail?.events)
    }

    @ViewBuilder private var occurrenceDetail: some View {
        if let occurrence = selectedOccurrence {
            AlertDetailView(
                occurrence: occurrence,
                detail: model.detail?.occurrence.id == occurrence.id ? model.detail : nil,
                detailProblem: model.detailProblem,
                silence: SilenceActions(model))
        } else {
            ContentUnavailableView("Select an alert", systemImage: "bell")
        }
    }
}
