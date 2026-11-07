import AchtungDomain
import SwiftUI

/// What Achtung tracked about the occurrence, beyond what the source reported.
struct OccurrenceFacts: View {
    let occurrence: Occurrence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delivery")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                fact("Source", occurrence.source)
                fact("Notifications", occurrence.notificationCount.formatted())
                fact("First received", exact(occurrence.firstReceivedAt))
                fact("Last received", exact(occurrence.lastReceivedAt))
            }
            .font(.callout)
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
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
                    Text("Earlier occurrences")
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
