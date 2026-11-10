import AchtungDomain
import SwiftUI

/// A channel's occurrences, most recently changed first. What changed since the user last
/// left the app sits above a "new" divider. Scrolling to the end loads older pages. With
/// read alerts hidden, only new ones and resends are listed, and an empty list says so.
struct AlertList: View {
    let occurrences: [Occurrence]
    let readState: ReadState
    let hasOlder: Bool
    /// The last successful refresh; a failed page load retries after the next one.
    let lastUpdated: Date?
    let loadOlder: () async -> Void
    @Binding var hidesRead: Bool
    @Binding var selection: Int?
    /// Copies an occurrence for an agent, from a row's context menu.
    let copy: (Occurrence) -> Void
    /// Silences, changes or ends a silence from a row's context menu.
    let silence: SilenceActions

    /// What a silence from the context menu came to, when it needs saying: an error, or a
    /// broader silence that still mutes the alert.
    @State private var silenceMessage: String?

    var body: some View {
        if occurrences.isEmpty && hidesRead {
            CaughtUpView { hidesRead = false }
        } else if occurrences.isEmpty && !hasOlder {
            AllClearView()
        } else {
            List(selection: $selection) {
                OccurrenceStream(
                    occurrences: occurrences, readState: readState, hasOlder: hasOlder,
                    lastUpdated: lastUpdated, loadOlder: loadOlder
                ) { occurrence in
                    AlertRow(occurrence: occurrence, isRead: readState.isRead(occurrence))
                        .contextMenu {
                            Button("Copy for Agent", systemImage: "doc.on.doc") {
                                copy(occurrence)
                            }
                            Divider()
                            silenceItems(for: occurrence)
                        }
                }
            }
            .animation(.default, value: occurrences.map(\.id))
            .alert(
                "Silence",
                isPresented: Binding(
                    get: { silenceMessage != nil }, set: { if !$0 { silenceMessage = nil } }),
                actions: { Button("OK") { silenceMessage = nil } },
                message: { Text(silenceMessage ?? "") })
        }
    }

    /// The same choices as the detail's silence button (`SilenceButton`).
    @ViewBuilder private func silenceItems(for occurrence: Occurrence) -> some View {
        let isSilenced = occurrence.isSilenced(at: .now)
        Menu(isSilenced ? "Change Silence" : "Silence") {
            ForEach(SilenceDuration.allCases) { option in
                Button("For \(option.title)\(isSilenced ? " from Now" : "")") {
                    Task {
                        if let problem = await silence.silence(occurrence, option) {
                            silenceMessage = "Couldn't silence the alert: \(problem.detail)"
                        }
                    }
                }
            }
        }
        if isSilenced {
            Button("End Silence") {
                Task {
                    switch await silence.unsilence(occurrence) {
                    case .ended: break
                    case .stillSilenced(let until):
                        silenceMessage =
                            "Its own silence ended, but another silence still mutes it until "
                            + "\(timeOrDate(until))."
                    case .failed(let problem):
                        silenceMessage = "Couldn't end the silence: \(problem.detail)"
                    }
                }
            }
        }
    }
}

#Preview {
    AlertList(
        occurrences: SampleData.occurrences, readState: SampleData.readState, hasOlder: false,
        lastUpdated: nil, loadOlder: {}, hidesRead: .constant(false),
        selection: .constant(nil), copy: { _ in }, silence: .none)
}
