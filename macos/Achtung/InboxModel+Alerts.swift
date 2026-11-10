import AchtungAPI
import AchtungDomain
import Foundation

/// What a notification or the menu bar asks the window to show.
enum OpenRequest: Equatable {
    /// The alert, selected in its channel.
    case occurrence(Occurrence)
    case list(OccurrenceScope)
}

extension InboxModel {
    /// Every channel's occurrences as the feed has loaded them, newest change first.
    var feed: [Occurrence] { lists[.allChannels]?.occurrences ?? [] }

    /// Firing critical alerts nobody has read on this Mac and no silence mutes, newest
    /// change first: the menu bar's count and list.
    var unreadCritical: [Occurrence] {
        let now = Date.now
        return feed.filter {
            $0.alert.isFiring && $0.alert.severity == .critical && !readState.isRead($0)
                && !$0.isSilenced(at: now)
        }
    }

    /// Silences the occurrence's alert in Alertmanager for `duration` from now (ADR 0008),
    /// or changes its own silence to end then (ADR 0015), and shows the result in every list
    /// that holds it. Returns why it failed; this doesn't touch `problem`, which is about
    /// refreshing.
    func silence(_ occurrence: Occurrence, for duration: SilenceDuration) async -> ServerError? {
        do throws(ServerError) {
            replace(try await server.silence(occurrenceID: occurrence.id, for: duration))
            return nil
        } catch {
            return error
        }
    }

    /// Ends the alert's own silences (ADR 0015) and shows the result everywhere.
    func unsilence(_ occurrence: Occurrence) async -> UnsilenceOutcome {
        do throws(ServerError) {
            let unsilenced = try await server.unsilence(occurrenceID: occurrence.id)
            replace(unsilenced)
            return unsilenced.silenceEnd(at: .now).map { .stillSilenced(until: $0) } ?? .ended
        } catch {
            return .failed(error)
        }
    }

    /// Marks the occurrences with these ids read, where the feed has them unread; any it
    /// doesn't have are older than the read baseline, so read already.
    func markRead(ids: Set<Int>) {
        for occurrence in unread(ids: ids) {
            markRead(occurrence)
        }
    }

    /// Those of these occurrences the feed has unread.
    func unread(ids: Set<Int>) -> [Occurrence] {
        feed.filter { ids.contains($0.id) && !readState.isRead($0) }
    }
}

/// What ending an alert's silence came to.
enum UnsilenceOutcome: Equatable {
    case ended
    /// Its own silence ended, but a broader one still mutes it until then.
    case stillSilenced(until: Date)
    case failed(ServerError)
}
