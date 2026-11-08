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
    private(set) var detail: OccurrenceDetail?
    /// Why the selected occurrence's history didn't load; the next refresh retries.
    private(set) var detailProblem: ServerError?
    private(set) var readState: ReadState
    /// The last failed refresh or page load; nil once a refresh succeeds again.
    private(set) var problem: ServerError?
    private(set) var lastUpdated: Date?

    /// How many occurrences of the all-channels feed a refresh loads at most to count
    /// what's unread. Past the cap, counts cover only the newest occurrences.
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
            try await loadUnreadBacklog()
            if visiting, let scope {
                markVisited(scope)
            }
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

    /// Pages the all-channels feed back to the read baseline: anything older is read, so
    /// then every occurrence that can be unread is loaded and counted. Stops at the cap.
    private func loadUnreadBacklog() async throws(ServerError) {
        guard let baseline = readState.baseline else { return }
        while let loaded = lists[.allChannels]?.occurrences,
            loaded.count < Self.unreadBacklogCap,
            let oldest = loaded.last?.lastEventAt, oldest > baseline
        {
            // Nothing left, or Live's scrolling is loading the next page already.
            guard try await loadOlderPage(in: .allChannels) else { return }
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
