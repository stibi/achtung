import AchtungAPI
import AchtungDomain
import Foundation

/// The client's view of one server: channels, the occurrences loaded so far, the selected
/// occurrence's detail, and this Mac's read state. Views read it; only it talks to the
/// server.
@Observable @MainActor
final class InboxModel {
    let baseURL: URL
    private(set) var channels: [Channel] = []
    private(set) var lists: [OccurrenceScope: OccurrenceList] = [:]
    /// Everything firing now, in every channel: the Live timeline's open bars include
    /// alerts that started before its 24 hours, which the feed doesn't reach.
    private(set) var firing: [Occurrence] = []
    private(set) var detail: OccurrenceDetail?
    /// Why the selected occurrence's history didn't load; the next refresh retries.
    private(set) var detailProblem: ServerError?
    private(set) var readState: ReadState
    /// The last failed refresh or page load; nil once a refresh succeeds again.
    private(set) var problem: ServerError?
    private(set) var lastUpdated: Date?

    /// How many occurrences of the all-channels feed a refresh loads at most, for the unread
    /// counts and the Live timeline. Past the cap, both cover only the newest occurrences.
    static let unreadBacklogCap = 2000

    /// Where each list's next older page starts; absent once the oldest is loaded.
    private var olderCursors: [OccurrenceScope: String] = [:]
    private var loadingOlder: Set<OccurrenceScope> = []
    private let server: AchtungServer
    private let defaults: UserDefaults
    private let readStateKey: String

    init(baseURL: URL, defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        self.server = AchtungServer(baseURL: baseURL)
        self.defaults = defaults
        // Occurrence ids belong to one server, so each server has its own read state.
        self.readStateKey = "readState \(baseURL.absoluteString)"
        self.readState = Self.loadReadState(from: defaults, key: readStateKey)
    }

    func hasOlder(in scope: OccurrenceScope) -> Bool {
        olderCursors[scope] != nil
    }

    /// Instances and channels with their unread counts, in sidebar order. Counted from the
    /// all-channels feed, which every refresh loads down to the read baseline.
    var sidebar: [Instance] {
        Instance.sidebar(
            channels: channels, occurrences: lists[.allChannels]?.occurrences ?? [],
            readState: readState)
    }

    /// Reloads the channels and the all-channels feed (it holds what the unread counts are
    /// made of), and fetches what changed in a selected channel since the last refresh.
    /// `visiting` means the user has the list on screen in the active app, so whatever the
    /// refresh brings counts as seen for the sidebar dots of the channels it showed.
    func refresh(_ scope: OccurrenceScope?, visiting: Bool) async {
        do throws(ServerError) {
            channels = try await server.channels()
            setBaselineIfMissing()
            try await update(.allChannels)
            // The open channel's list before the backlog, which can take many pages.
            if case .channel = scope, let scope {
                try await update(scope)
            }
            try await loadFeedBacklog()
            if visiting, let scope {
                markVisited(scope)
            }
            // Only the timeline uses it, so a failure here doesn't stop the visit counting.
            firing = try await server.firingOccurrences()
            problem = nil
            lastUpdated = .now
        } catch {
            // A cancelled load is the user moving on, not a server problem.
            guard !Task.isCancelled else { return }
            problem = error
        }
    }

    func loadOlder(in scope: OccurrenceScope) async {
        do throws(ServerError) {
            try await loadOlderPage(in: scope)
        } catch {
            guard !Task.isCancelled else { return }
            problem = error
        }
    }

    /// Loads the history of `occurrence`, unless the user moved on before it arrived.
    func loadDetail(of occurrence: Occurrence) async {
        if detail?.occurrence.id != occurrence.id {
            detail = nil
            detailProblem = nil
        }
        do throws(ServerError) {
            let loaded = try await server.occurrence(id: occurrence.id)
            guard !Task.isCancelled else { return }
            detail = loaded
            detailProblem = nil
        } catch {
            guard !Task.isCancelled else { return }
            detailProblem = error
        }
    }

    /// Silences the occurrence's alert in Alertmanager (ADR 0008) and shows the silenced
    /// occurrence in every list that holds it. Returns why it failed, for the button to
    /// show; this doesn't touch `problem`, which is about refreshing.
    func silence(_ occurrence: Occurrence, for duration: SilenceDuration) async -> ServerError? {
        do throws(ServerError) {
            let silenced = try await server.silence(occurrenceID: occurrence.id, for: duration)
            for scope in lists.keys
            where lists[scope]?.occurrences.contains(where: { $0.id == silenced.id }) == true {
                lists[scope]?.merge([silenced])
            }
            return nil
        } catch {
            return error
        }
    }

    /// What a list shows, nil until its first page arrives: with read alerts hidden, the
    /// unread ones and `kept`, the occurrence the user has open (`ReadState.shown`).
    func shownOccurrences(in scope: OccurrenceScope, keeping kept: Int?) -> [Occurrence]? {
        guard let own = lists[scope]?.occurrences else { return nil }
        return readState.shown(
            own: own, feed: lists[.allChannels]?.occurrences ?? [], in: scope, keeping: kept)
    }

    func hidesRead(in scope: OccurrenceScope) -> Bool {
        readState.hidesRead(in: scope)
    }

    func setHidesRead(_ hides: Bool, in scope: OccurrenceScope) {
        readState.setHidesRead(hides, in: scope)
        saveReadState()
    }

    func markRead(_ occurrence: Occurrence) {
        readState.markRead(occurrence)
        saveReadState()
    }

    /// The user left the app. Whatever happened after the newest event the client had
    /// loaded is new when they come back. Server times only, so clock skew doesn't matter.
    func markSeen() {
        guard let latest = channels.compactMap(\.lastEventAt).max() else { return }
        readState.markSeen(upTo: latest)
        saveReadState()
    }

    /// Loads the next older page of `scope`. False when none is left or one is already
    /// loading (Live's scrolling and the unread backlog share the feed).
    @discardableResult
    private func loadOlderPage(in scope: OccurrenceScope) async throws(ServerError) -> Bool {
        guard let cursor = olderCursors[scope], loadingOlder.insert(scope).inserted else {
            return false
        }
        defer { loadingOlder.remove(scope) }
        let page = try await server.occurrences(in: scope, after: cursor)
        lists[scope, default: OccurrenceList()].merge(page.occurrences)
        olderCursors[scope] = page.nextCursor
        return true
    }

    /// Pages the all-channels feed back far enough for the unread counts and the Live
    /// timeline: to the read baseline (anything older is read, so then every occurrence
    /// that can be unread is loaded and counted) and to the start of the timeline's 24
    /// hours, whichever is further back. Stops at the cap. A load that reaches the baseline
    /// moves it forward (`ReadState.advanceBaseline`).
    private func loadFeedBacklog() async throws(ServerError) {
        let timelineStart = TimelineWindow(endingAt: .now).start
        let target = min(readState.baseline ?? timelineStart, timelineStart)
        while let loaded = lists[.allChannels]?.occurrences,
            loaded.count < Self.unreadBacklogCap,
            let oldest = loaded.last?.lastEventAt, oldest > target
        {
            // Nothing left, or Live's scrolling is loading the next page already.
            guard try await loadOlderPage(in: .allChannels) else { break }
        }
        // If the feed now reaches back to the baseline (not stopped by the cap or by Live's
        // paging), move the baseline up so the next launch has less to page through.
        let feed = lists[.allChannels]?.occurrences ?? []
        if readState.advanceBaseline(over: feed, hasOlder: hasOlder(in: .allChannels)) {
            saveReadState()
        }
    }

    /// On the first refresh with unread counts, everything up to the newest event on the
    /// server counts as read. A server without events yet has no backlog to hide.
    private func setBaselineIfMissing() {
        guard readState.baseline == nil else { return }
        readState.setBaselineIfMissing(channels.compactMap(\.lastEventAt).max() ?? .distantPast)
        saveReadState()
    }

    private func update(_ scope: OccurrenceScope) async throws(ServerError) {
        if let since = lists[scope]?.refreshSince {
            let changed = try await server.occurrences(in: scope, changedSince: since)
            lists[scope]?.merge(changed)
        } else {
            let page = try await server.occurrences(in: scope)
            var list = OccurrenceList()
            list.merge(page.occurrences)
            lists[scope] = list
            olderCursors[scope] = page.nextCursor
        }
    }

    /// A channel's newest change is always the first row of its own list. Live is one feed
    /// across channels, so it has shown a channel's newest change only if that change is
    /// within the pages loaded so far.
    private func markVisited(_ scope: OccurrenceScope) {
        switch scope {
        case .channel(let id):
            for channel in channels where channel.id == id {
                readState.markVisited(channel)
            }
        case .allChannels:
            let complete = !hasOlder(in: .allChannels)
            let oldestLoaded = lists[.allChannels]?.occurrences.last?.lastEventAt
            for channel in channels {
                guard let lastEventAt = channel.lastEventAt else { continue }
                if complete || oldestLoaded.map({ lastEventAt >= $0 }) == true {
                    readState.markVisited(channel)
                }
            }
        }
        saveReadState()
    }

    private func saveReadState() {
        do {
            defaults.set(try JSONEncoder().encode(readState), forKey: readStateKey)
        } catch {
            preconditionFailure("ReadState is plain data and always encodes: \(error)")
        }
    }

    private static func loadReadState(from defaults: UserDefaults, key: String) -> ReadState {
        guard let data = defaults.data(forKey: key) else { return ReadState() }
        // A format from an older build starts over; the next refresh sets a new baseline.
        return (try? JSONDecoder().decode(ReadState.self, from: data)) ?? ReadState()
    }
}
