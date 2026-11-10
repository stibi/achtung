import AchtungAPI
import AchtungDomain
import SwiftUI

/// Starts a search for a filter, e.g. from a label's context menu in an alert's details.
struct SearchAlertsAction {
    let run: (SearchToken) -> Void

    func callAsFunction(_ token: SearchToken) {
        run(token)
    }
}

extension EnvironmentValues {
    /// Nil where there is no search to start.
    @Entry var searchAlerts: SearchAlertsAction?
}

/// The search across every channel (ADR 0017), as the window's search field has it:
/// typed text, and the finished words that are filters ("namespace=payments",
/// "severity:critical", "instance:cdx") as tokens.
struct SearchQuery: Equatable {
    var text = ""
    var tokens: [SearchToken] = []

    var search: OccurrenceSearch { OccurrenceSearch(text: text, tokens: tokens) }

    /// Moves the finished words that are filters into tokens; with `all`, the last word
    /// too (on Return).
    mutating func tokenize(all: Bool = false) {
        let tokenized = SearchToken.tokenize(text: text, tokens: tokens, all: all)
        guard tokenized.tokens != tokens || tokenized.text != text else { return }
        (text, tokens) = tokenized
    }
}

/// What a search found, newest change first, each row with its channel; clicking one opens
/// it in its channel. Refreshed with the rest of the inbox, paged like a channel.
struct SearchResults: View {
    let model: InboxModel
    let search: OccurrenceSearch
    /// Shows an occurrence in its channel, which ends the search.
    let open: (Occurrence) -> Void

    private var scope: OccurrenceScope { .search(search) }

    /// Arrow keys move it without leaving the search; a click or Return opens the alert.
    @State private var selection: Int?

    var body: some View {
        content
            // A new search starts with no row selected.
            .onChange(of: search) {
                if selection != nil {
                    selection = nil
                }
            }
            .navigationTitle("Search")
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Search")
                            .font(.headline)
                        Text(search.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }

    @ViewBuilder private var content: some View {
        if let occurrences = model.shownOccurrences(in: scope, keeping: nil) {
            if occurrences.isEmpty && !model.hasOlder(in: scope) {
                ContentUnavailableView {
                    Label("No alerts match", systemImage: "magnifyingglass")
                } description: {
                    Text(search.description)
                }
            } else {
                AlertList(
                    occurrences: occurrences, readState: model.readState,
                    hasOlder: model.hasOlder(in: scope), lastUpdated: model.lastUpdated,
                    loadOlder: { await model.loadOlder(in: scope) },
                    hidesRead: .constant(false), selection: $selection,
                    copy: { copyForAgent($0, events: nil) }, silence: SilenceActions(model),
                    showsChannel: true, open: open)
            }
        } else if let problem = model.listProblems[scope] {
            // E.g. the server's 400 for a filter it doesn't take, like an invalid instance.
            ContentUnavailableView {
                Label("Couldn't search", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text(problem.detail)
            }
        } else {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The window's search field (⌘F), its tokens, and when a search starts and ends: a
/// typed query searches after a pause of 300 ms; clearing it returns to the list that was
/// open, which the search never changed.
struct InboxSearch: ViewModifier {
    let model: InboxModel
    @Binding var query: SearchQuery
    @Binding var active: OccurrenceSearch?

    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: $query.text, tokens: $query.tokens, placement: .toolbar,
                prompt: "Search alerts, or name=value"
            ) { token in
                Text(token.title)
            }
            .searchFocused($isFocused)
            .onChange(of: query.text) { query.tokenize() }
            .onSubmit(of: .search) { query.tokenize(all: true) }
            .task(id: query) {
                let search = query.search
                guard !search.isEmpty else {
                    end()
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return  // Typed on: the next search replaces this one.
                }
                active = search
                model.forgetSearches(except: search)
            }
            .environment(
                \.searchAlerts,
                SearchAlertsAction { token in query = SearchQuery(tokens: [token]) }
            )
            .background {
                // ⌘F, as in other Mac apps; the search field has no shortcut of its own.
                Button("Search") { isFocused = true }
                    .keyboardShortcut("f")
                    .opacity(0)
                    .accessibilityHidden(true)
            }
    }

    private func end() {
        guard active != nil else { return }
        active = nil
        model.forgetSearches()
    }
}
