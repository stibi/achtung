import AchtungAPI
import AchtungDomain
import SwiftUI

/// A channel's detail pane: what the source reported in the main column, and the
/// occurrence's metadata (channel, identity, delivery, history) in a panel on the right.
/// Each scrolls on its own. When the pane is too narrow for both, the panel goes below.
struct AlertDetailView: View {
    /// Narrower than this, the panel stacks below the main column.
    private static let sideBySideWidth: CGFloat = 400 + AlertMetadataPanel.width
    /// The panel card's distance from the pane's edges.
    private static let cardMargin: CGFloat = 10

    let occurrence: Occurrence
    /// Nil while the history is loading, or when it failed to load.
    let detail: OccurrenceDetail?
    let detailProblem: ServerError?
    let silence: SilenceActions

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= Self.sideBySideWidth {
                HStack(spacing: 0) {
                    ScrollView {
                        details
                            .padding(24)
                    }
                    // The card's contents scroll inside it; the main column's padding is
                    // the gap on its left.
                    ScrollView {
                        panel
                    }
                    .frame(width: AlertMetadataPanel.width)
                    .paneCard()
                    .padding([.top, .trailing, .bottom], Self.cardMargin)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        details
                            .padding(24)
                        panel
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .paneCard()
                            .padding(Self.cardMargin)
                    }
                }
            }
        }
    }

    private var details: some View {
        AlertDetails(
            occurrence: occurrence, silence: silence, events: detail?.events,
            hasCopyShortcut: true)
    }

    private var panel: some View {
        AlertMetadataPanel(occurrence: occurrence, detail: detail, detailProblem: detailProblem)
            .padding(20)
    }
}

/// What the source reported about one occurrence: header, the summary and description to
/// read, links and the silence and copy buttons, then every annotation and every label,
/// one per line. Shared by the channel detail pane and the Live cards.
struct AlertDetails: View {
    let occurrence: Occurrence
    let silence: SilenceActions
    /// The history, for "Copy for Agent", once it has loaded; Live's cards don't have it.
    var events: [OccurrenceEvent]?
    /// ⇧⌘C copies: only in the detail pane, where one alert is shown.
    var hasCopyShortcut = false

    private var alert: IncomingAlert { occurrence.alert }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SilenceState(occurrence: occurrence) { isSilenced in
                VStack(alignment: .leading, spacing: 20) {
                    AlertHeader(
                        alert: alert, silencedUntil: isSilenced ? occurrence.silencedUntil : nil,
                        resentAt: occurrence.isResent ? occurrence.lastEventAt : nil)
                    AlertProse(alert: alert)
                    FlowLayout(spacing: 8) {
                        AlertLinkButtons(alert: alert)
                        // A new occurrence gets a fresh button, without the last one's error
                        // or in-flight state.
                        SilenceButton(
                            occurrence: occurrence, isSilenced: isSilenced, actions: silence
                        )
                        .id(occurrence.id)
                        CopyForAgentButton(
                            occurrence: occurrence, events: events, hasShortcut: hasCopyShortcut
                        )
                        .id(occurrence.id)
                    }
                }
            }
            AnnotationsSection(alert: alert)
            LabelsSection(alert: alert)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AlertHeader: View {
    let alert: IncomingAlert
    let silencedUntil: Date?
    let resentAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: alert.severity.symbolName)
                .font(.system(size: 26))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(alert.severity.color.gradient, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Text(alert.title)
                    .font(.title.bold())
                HStack(spacing: 8) {
                    StatusPill(alert: alert)
                    if let resentAt {
                        ResentPill(date: resentAt)
                    }
                    if let silencedUntil {
                        SilencedPill(until: silencedUntil)
                    }
                    Text(alert.severity.rawValue.capitalized)
                        .foregroundStyle(alert.severity.color)
                    RelativeTime(date: alert.startsAt)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Text(absoluteTimes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// Exact times, for triage; the relative time above is for scanning.
    private var absoluteTimes: String {
        let started = "Started \(alert.startsAt.formatted(date: .abbreviated, time: .shortened))"
        switch alert.state {
        case .firing:
            return started
        case .resolved(let endsAt):
            return "\(started) · Resolved \(endsAt.formatted(date: .abbreviated, time: .shortened))"
        }
    }
}
