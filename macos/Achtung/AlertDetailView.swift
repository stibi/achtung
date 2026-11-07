import AchtungAPI
import AchtungDomain
import SwiftUI

/// Everything about one occurrence: what the source reported, what Achtung tracked, and
/// its history once `detail` has loaded.
struct AlertDetailView: View {
    let occurrence: Occurrence
    /// Nil while the history is loading, or when it failed to load.
    let detail: OccurrenceDetail?
    let detailProblem: ServerError?

    private var alert: IncomingAlert { occurrence.alert }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AlertHeader(alert: alert)
                if !alert.links.isEmpty {
                    LinkButtons(links: alert.links)
                }
                KeyValueSection(title: "Annotations", values: alert.annotations)
                KeyValueSection(title: "Labels", values: alert.labels)
                OccurrenceFacts(occurrence: occurrence)
                if let detail {
                    OccurrenceHistory(detail: detail)
                } else if let detailProblem {
                    Label(
                        "History unavailable: \(detailProblem.title). Retrying soon.",
                        systemImage: "exclamationmark.icloud"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(detailProblem.detail)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}

private struct AlertHeader: View {
    let alert: IncomingAlert

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
