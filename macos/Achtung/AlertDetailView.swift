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
    let silence: SilenceAction

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= Self.sideBySideWidth {
                HStack(spacing: 0) {
                    ScrollView {
                        AlertDetails(occurrence: occurrence, silence: silence)
                            .padding(24)
                    }
                    // The card's contents scroll inside it; the main column's padding is
                    // the gap on its left.
                    ScrollView {
                        panel
                    }
                    .frame(width: AlertMetadataPanel.width)
                    .metadataCard()
                    .padding([.top, .trailing, .bottom], Self.cardMargin)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AlertDetails(occurrence: occurrence, silence: silence)
                            .padding(24)
                        panel
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .metadataCard()
                            .padding(Self.cardMargin)
                    }
                }
            }
        }
    }

    private var panel: some View {
        AlertMetadataPanel(occurrence: occurrence, detail: detail, detailProblem: detailProblem)
            .padding(20)
    }
}

extension View {
    /// The metadata panel as a card set into the pane: rounded, on a material, with a
    /// hairline border and a very soft shadow. Content is clipped to the card.
    fileprivate func metadataCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return
            self
            .background(.regularMaterial, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

/// What the source reported about one occurrence: header, links and the silence button,
/// annotations and labels. Shared by the channel detail pane and the Live cards.
struct AlertDetails: View {
    let occurrence: Occurrence
    let silence: SilenceAction

    private var alert: IncomingAlert { occurrence.alert }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SilenceState(occurrence: occurrence) { isSilenced in
                VStack(alignment: .leading, spacing: 24) {
                    AlertHeader(
                        alert: alert, silencedUntil: isSilenced ? occurrence.silencedUntil : nil)
                    HStack(spacing: 8) {
                        if !alert.links.isEmpty {
                            LinkButtons(links: alert.links)
                        }
                        // A new occurrence gets a fresh button, without the last one's error
                        // or in-flight state.
                        SilenceButton(
                            occurrence: occurrence, isSilenced: isSilenced, silence: silence
                        )
                        .id(occurrence.id)
                    }
                }
            }
            KeyValueSection(title: "Annotations", values: alert.annotations)
            KeyValueSection(title: "Labels", values: alert.labels)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AlertHeader: View {
    let alert: IncomingAlert
    let silencedUntil: Date?

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
                if let summary = alert.summary {
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                }
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

private struct LinkButtons: View {
    let links: [AlertLink]

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack {
            ForEach(links, id: \.url) { link in
                Button {
                    openURL(link.url)
                } label: {
                    Label(link.kind.rawValue.capitalized, systemImage: link.kind.symbolName)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct KeyValueSection: View {
    let title: String
    let values: [String: String]

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(values.sorted { $0.key < $1.key }, id: \.key) { entry in
                        GridRow {
                            Text(entry.key)
                                .foregroundStyle(.secondary)
                            Text(entry.value)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout.monospaced())
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            }
        }
    }
}
