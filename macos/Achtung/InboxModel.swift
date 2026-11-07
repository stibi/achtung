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
    private(set) var lists: [String: OccurrenceList] = [:]
    private(set) var detail: OccurrenceDetail?
    /// Why the selected occurrence's history didn't load; the next refresh retries.
    private(set) var detailProblem: ServerError?
    private(set) var readState: ReadState
    /// The last failed refresh or page load; nil once a refresh succeeds again.
    private(set) var problem: ServerError?
    private(set) var lastUpdated: Date?

    /// Where each channel's next older page starts; absent once the oldest is loaded.
    private var olderCursors: [String: String] = [:]
    private var loadingOlder: Set<String> = []
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

    func hasOlder(in channel: String) -> Bool {
        olderCursors[channel] != nil
    }

    /// Reloads the channels and fetches what changed in `channel` since the last refresh.
    /// `visiting` means the user has the channel on screen in the active app, so whatever
    /// the refresh brings counts as seen for its sidebar dot.
    func refresh(_ channel: String?, visiting: Bool) async {
        do throws(ServerError) {
            channels = try await server.channels()
            if let channel {
                try await update(channel)
                if visiting, let visited = channels.first(where: { $0.slug == channel }) {
                    readState.markVisited(visited)
                    saveReadState()
                }
            }
            problem = nil
            lastUpdated = .now
        } catch {
            // A cancelled load is the user moving on, not a server problem.
            guard !Task.isCancelled else { return }
            problem = error
        }
    }

    func loadOlder(in channel: String) async {
        guard let cursor = olderCursors[channel], loadingOlder.insert(channel).inserted else {
            return
        }
        defer { loadingOlder.remove(channel) }
        do throws(ServerError) {
            let page = try await server.occurrences(in: channel, after: cursor)
            lists[channel, default: OccurrenceList()].merge(page.occurrences)
            olderCursors[channel] = page.nextCursor
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

    private func update(_ channel: String) async throws(ServerError) {
        if let since = lists[channel]?.refreshSince {
            let changed = try await server.occurrences(in: channel, changedSince: since)
            lists[channel]?.merge(changed)
        } else {
            let page = try await server.occurrences(in: channel)
            var list = OccurrenceList()
            list.merge(page.occurrences)
            lists[channel] = list
            olderCursors[channel] = page.nextCursor
        }
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
        // A format from an older build starts over: everything shows as unread once.
        return (try? JSONDecoder().decode(ReadState.self, from: data)) ?? ReadState()
    }
}
