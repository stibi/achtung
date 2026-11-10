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
}
