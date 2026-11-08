import AchtungDomain
import SwiftUI

/// What Achtung tracked about the occurrence, beyond what the source reported, as a Live
/// card shows it. The detail pane shows the same in `AlertMetadataPanel`.
struct OccurrenceFacts: View {
    let occurrence: Occurrence

    var body: some View {
        FactsSection(
            title: "Delivery",
            facts: [("Source", occurrence.source)] + deliveryFacts(of: occurrence))
    }
}

/// How often and when the occurrence's notifications arrived.
func deliveryFacts(of occurrence: Occurrence) -> [(name: String, value: String)] {
    [
        ("Notifications", occurrence.notificationCount.formatted()),
        ("First received", exact(occurrence.firstReceivedAt)),
        ("Last received", exact(occurrence.lastReceivedAt)),
    ]
}

/// A heading over name/value rows.
struct FactsSection: View {
    let title: String
    let facts: [(name: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(facts, id: \.name) { fact in
                    GridRow {
                        Text(fact.name).foregroundStyle(.secondary)
                        Text(fact.value).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
    }
}

/// The occurrence's events, oldest first, and the alert's other occurrences.
struct OccurrenceHistory: View {
    let detail: OccurrenceDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("History")
                    .font(.headline)
                ForEach(detail.events) { event in
                    Label {
                        Text("\(event.kind.title) \(exact(event.recordedAt))")
                    } icon: {
                        Image(systemName: event.kind.symbolName)
                            .foregroundStyle(event.kind.color)
                    }
                    .font(.callout)
                }
            }
            if !detail.otherOccurrences.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    // Can hold newer ones too, when an older occurrence is open.
                    Text("Other occurrences")
                        .font(.headline)
                    ForEach(detail.otherOccurrences) { other in
                        HStack(spacing: 8) {
                            StatusPill(alert: other.alert)
                            Text("Started \(exact(other.alert.startsAt))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private func exact(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}

extension OccurrenceEvent.Kind {
    fileprivate var title: String {
        switch self {
        case .fired: "Fired"
        case .resolved: "Resolved"
        case .reopened: "Reopened"
        }
    }

    fileprivate var symbolName: String {
        switch self {
        case .fired: "flame.fill"
        case .resolved: "checkmark.circle.fill"
        case .reopened: "arrow.uturn.backward.circle.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        // Red stays reserved for critical severity.
        case .fired, .reopened: .primary
        case .resolved: .green
        }
    }
}
