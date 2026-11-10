import AchtungDomain
import SwiftUI

// Where the window goes: the list on screen, the sidebar's selection, alerts opened from a
// notification, the menu bar or a search, and the first unread alert of a channel just
// opened.
extension InboxView {
    /// The list on screen: the search, else the selected list.
    var shownScope: OccurrenceScope? {
        activeSearch.map { .search($0) } ?? selectedScope
    }

    /// The alert whose detail is on screen: a channel's selected one, unless a search
    /// covers it. Live and the lists themselves don't count: a row may be out of sight.
    var viewedOccurrenceID: Int? {
        guard activeSearch == nil, case .channel = selectedScope else { return nil }
        return selectedOccurrence?.id
    }

    /// The sidebar's selection; choosing a row, even the one selected, ends a search.
    var sidebarSelection: Binding<InboxPage?> {
        Binding {
            page
        } set: {
            page = $0
            query = SearchQuery()
        }
    }

    func takeOpenRequest() {
        guard let request = model.openRequest else { return }
        model.openRequest = nil
        query = SearchQuery()  // Going somewhere ends a search.
        switch request {
        case .occurrence(let occurrence):
            revealed = occurrence
            page = .list(.channel(occurrence.channel))
            selectedID = occurrence.id
        case .list(let scope):
            page = .list(scope)
        }
    }

    func selectFirstUnread() {
        guard let scope = selectFirstUnreadIn, scope == selectedScope,
            let occurrences = model.shownOccurrences(in: scope, keeping: nil)
        else { return }
        // Once, on opening the channel: selecting marks it read, and with read alerts
        // hidden, selecting the next unread one each time would read the whole list.
        selectedID = model.readState.firstUnread(in: occurrences)?.id
        selectFirstUnreadIn = nil
    }
}
