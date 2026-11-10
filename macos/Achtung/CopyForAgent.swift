import AchtungDomain
import AppKit
import SwiftUI

/// Puts an occurrence on the pasteboard as Markdown for an agent to investigate
/// (`AgentReport`), with its history when it has loaded.
@MainActor
func copyForAgent(_ occurrence: Occurrence, events: [OccurrenceEvent]?) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
        AgentReport.markdown(for: occurrence, events: events), forType: .string)
}

/// "Copy for Agent", which says "Copied" for a moment after copying. With `hasShortcut`,
/// ⇧⌘C copies too: only the one detail pane has it, not each of Live's cards.
struct CopyForAgentButton: View {
    let occurrence: Occurrence
    let events: [OccurrenceEvent]?
    let hasShortcut: Bool

    /// Counts copies; "Copied" shows for a moment from the latest one.
    @State private var copies = 0
    @State private var copied = false

    var body: some View {
        Button {
            copyForAgent(occurrence, events: events)
            copies += 1
        } label: {
            Label(
                copied ? "Copied" : "Copy for Agent",
                systemImage: copied ? "checkmark" : "doc.on.doc"
            )
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(hasShortcut ? KeyboardShortcut("c", modifiers: [.command, .shift]) : nil)
        .help(
            "Copy the alert's details as Markdown, to give an agent to investigate"
                + (hasShortcut ? " (⇧⌘C)" : "")
        )
        .task(id: copies) {
            guard copies > 0 else { return }
            withAnimation(.snappy) { copied = true }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { copied = false }
        }
    }
}
