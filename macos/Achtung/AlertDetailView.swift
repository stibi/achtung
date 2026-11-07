import AchtungDomain
import SwiftUI

struct AlertDetailView: View {
    let alert: IncomingAlert

    var body: some View {
        Form {
            Section {
                LabeledContent("Severity", value: alert.severity.rawValue)
                LabeledContent("Status", value: status)
                LabeledContent("Started", value: alert.startsAt.formatted())
                if let summary = alert.summary {
                    Text(summary)
                }
            }
            KeyValueSection(title: "Annotations", values: alert.annotations)
            KeyValueSection(title: "Labels", values: alert.labels)
            Section("Links") {
                ForEach(alert.links, id: \.url) { link in
                    Link(link.kind.rawValue, destination: link.url)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(alert.title)
    }

    private var status: String {
        switch alert.state {
        case .firing:
            "Firing"
        case .resolved(let endsAt):
            "Resolved \(endsAt.formatted())"
        }
    }
}

private struct KeyValueSection: View {
    let title: String
    let values: [String: String]

    var body: some View {
        Section(title) {
            ForEach(values.sorted { $0.key < $1.key }, id: \.key) { entry in
                LabeledContent(entry.key, value: entry.value)
            }
        }
    }
}
