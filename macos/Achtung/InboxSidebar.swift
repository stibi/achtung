import AchtungDomain
import SwiftUI

/// Live, then each instance (the sending system, ADR 0006) with its channels underneath,
/// in the order `Instance.sidebar` gives: anything unread first, then by name.
struct InboxSidebar: View {
    let model: InboxModel
    @Binding var selection: OccurrenceScope?

    @State private var collapsedInstances: Set<String> = []

    var body: some View {
        let instances = model.sidebar
        List(selection: $selection) {
            SidebarRow(
                title: "Live", systemImage: "dot.radiowaves.left.and.right",
                unread: instances.reduce(0) { $0 + $1.unread },
                unreadCritical: instances.reduce(0) { $0 + $1.unreadCritical },
                hasNews: model.channels.contains { model.readState.hasNews($0) }
            )
            .tag(OccurrenceScope.allChannels)
            Section("Channels") {
                ForEach(instances) { instance in
                    DisclosureGroup(isExpanded: expanded(instance)) {
                        ForEach(instance.channels) { summary in
                            SidebarRow(
                                title: summary.id.slug, systemImage: "number",
                                unread: summary.unread, unreadCritical: summary.unreadCritical,
                                hasNews: model.readState.hasNews(summary.channel)
                            )
                            .tag(OccurrenceScope.channel(summary.id))
                        }
                    } label: {
                        SidebarRow(
                            title: instance.name, systemImage: "server.rack",
                            unread: instance.unread, unreadCritical: instance.unreadCritical,
                            hasNews: instance.channels.contains {
                                model.readState.hasNews($0.channel)
                            })
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        .safeAreaInset(edge: .bottom) {
            if let problem = model.problem {
                ConnectionBanner(problem: problem, lastUpdated: model.lastUpdated)
            }
        }
    }

    /// Instances start expanded; the user can fold any of them away.
    private func expanded(_ instance: Instance) -> Binding<Bool> {
        Binding(
            get: { !collapsedInstances.contains(instance.name) },
            set: { isExpanded in
                if isExpanded {
                    collapsedInstances.remove(instance.name)
                } else {
                    collapsedInstances.insert(instance.name)
                }
            })
    }
}

/// One sidebar row. Trailing badge: unread occurrences. Next to the name, in white on red:
/// unread critical ones. Dot: something happened since the user last looked. A row with
/// nothing unread is greyed out.
private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let unread: Int
    let unreadCritical: Int
    let hasNews: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(unread == 0 ? .secondary : .primary)
            if unreadCritical > 0 {
                Text(unreadCritical.formatted())
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
                    .help("Unread critical alerts")
            }
            Spacer()
            if hasNews {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .help("Changed since you last looked")
            }
        }
        .badge(unread)
    }
}
