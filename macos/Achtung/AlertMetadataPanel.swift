import AchtungAPI
import AchtungDomain
import SwiftUI

/// The detail pane's right-hand column: where the occurrence belongs, which alert it is,
/// how it was delivered, and its history once `detail` has loaded.
struct AlertMetadataPanel: View {
    static let width: CGFloat = 280

    let occurrence: Occurrence
    /// Nil while the history is loading, or when it failed to load.
    let detail: OccurrenceDetail?
    let detailProblem: ServerError?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Channel")
                    .font(.headline)
                Text("\(occurrence.channel.instance) · #\(occurrence.channel.slug)")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            identity
            FactsSection(title: "Delivery", facts: deliveryFacts(of: occurrence))
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
    }

    /// The alert's identity in its source, e.g. Alertmanager's fingerprint.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identity")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Source").foregroundStyle(.secondary)
                    Text(occurrence.source).textSelection(.enabled)
                }
                GridRow {
                    Text("Key").foregroundStyle(.secondary)
                    Text(occurrence.alert.sourceKey)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(occurrence.alert.sourceKey)
                }
            }
            .font(.callout)
        }
    }
}
