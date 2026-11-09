import AchtungAPI
import AchtungDomain
import AppKit
import SwiftUI

/// What an Alertmanager tile opens on Home: its active alerts grouped by severity, most
/// severe first, then its silenced and inhibited ones, folded away. They come from the
/// same read as the tile's counts. Back (or Esc) returns to Home. It reloads every 30
/// seconds while the app is on screen, and on ⌘R; the list scrolls like any other.
struct AlertmanagerDetailView: View {
    private static let refreshInterval = Duration.seconds(30)

    let model: InboxModel
    let instance: String
    /// Shows an occurrence in its channel.
    let open: (Occurrence) -> Void
    let back: () -> Void

    /// Why opening an alert's occurrence failed, shown above the list.
    @State private var openProblem: ServerError?

    private var alerts: AlertmanagerAlerts? { model.homeModel.alertmanagerAlerts[instance] }
    private var problem: ServerError? { model.homeModel.alertmanagerProblems[instance] }

    var body: some View {
        content
            .navigationTitle(instance)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    AlertmanagerHeader(
                        instance: instance, alerts: alerts, problem: problem, back: back
                    ) {
                        Task { await model.homeModel.refreshAlerts(of: instance) }
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .task(id: instance) {
                while !Task.isCancelled {
                    if NSApp.occlusionState.contains(.visible) {
                        await model.homeModel.refreshAlerts(of: instance)
                    }
                    do {
                        try await Task.sleep(for: Self.refreshInterval)
                    } catch {
                        return  // Cancelled: back to Home, or the window closed.
                    }
                }
            }
            // Back on screen: catch up right away, as Home does.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didChangeOcclusionStateNotification)
            ) { _ in
                if NSApp.occlusionState.contains(.visible) {
                    Task { await model.homeModel.refreshAlerts(of: instance) }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let alerts {
            ScrollView {
                // The "since" times move on every minute between refreshes.
                TimelineView(.everyMinute) { context in
                    AlertGroups(alerts: alerts, now: context.date, open: openOccurrence)
                }
                .padding(24)
            }
            .safeAreaInset(edge: .top) {
                if let openProblem {
                    Label(
                        "Couldn't open the alert: \(openProblem.detail)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
                    .background(.background, in: .rect(cornerRadius: 8))
                    .padding(8)
                }
            }
        } else if case .notFound = problem {
            // Gone from the server's configuration since Home listed it.
            ContentUnavailableView {
                Label("No Alertmanager \(instance)", systemImage: "server.rack")
            } description: {
                Text("The server no longer has an Alertmanager for this instance.")
            } actions: {
                Button("Back to Home", action: back)
            }
        } else if let problem {
            UnreachableView(problem: problem, baseURL: model.baseURL) {
                Task { await model.homeModel.refreshAlerts(of: instance) }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The rows know only the occurrence's id: load it, then show it in its channel.
    private func openOccurrence(id: Int) {
        openProblem = nil
        Task {
            do throws(ServerError) {
                open(try await model.homeModel.occurrence(id: id))
            } catch {
                openProblem = error
            }
        }
    }
}

/// The active alerts by severity, or "All quiet", then the silenced and inhibited ones.
private struct AlertGroups: View {
    let alerts: AlertmanagerAlerts
    let now: Date
    let open: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if case .unreachable(let error, let lastRead) = alerts.status {
                Label(
                    lastRead.map { "\(error). Showing the read from \(timeOrDate($0))." }
                        ?? "\(error). It has never been read.",
                    systemImage: "bolt.horizontal.circle"
                )
                .foregroundStyle(.red)
            }
            let groups = alerts.activeBySeverity
            if groups.isEmpty, alerts.checkedAt != nil {
                Label("All quiet", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
            }
            ForEach(groups, id: \.severity) { group in
                VStack(alignment: .leading, spacing: 6) {
                    GroupHeader(
                        title: group.severity.groupTitle, count: group.alerts.count,
                        color: group.severity.color)
                    AlertCard(alerts: group.alerts, now: now, open: open)
                }
            }
            FoldedGroup(title: "Silenced", alerts: alerts.silenced, now: now, open: open)
            FoldedGroup(title: "Inhibited", alerts: alerts.inhibited, now: now, open: open)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GroupHeader: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(color)
            Text(count.formatted())
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(color, in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}

/// A group's alerts on one card, divided.
private struct AlertCard: View {
    let alerts: [AlertmanagerAlert]
    let now: Date
    let open: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                if index > 0 {
                    Divider()
                }
                AlertmanagerAlertRow(alert: alert, now: now, open: open)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

/// "Silenced (4)", folded until opened; nothing when there are none.
private struct FoldedGroup: View {
    let title: String
    let alerts: [AlertmanagerAlert]
    let now: Date
    let open: (Int) -> Void

    var body: some View {
        if !alerts.isEmpty {
            // Folded until opened, as a DisclosureGroup starts.
            DisclosureGroup {
                AlertCard(alerts: alerts, now: now, open: open)
                    .padding(.top, 6)
            } label: {
                Text("\(title) (\(alerts.count))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Back to Home, the Alertmanager with its status dot, when it was read, and a reload.
private struct AlertmanagerHeader: View {
    let instance: String
    let alerts: AlertmanagerAlerts?
    let problem: ServerError?
    let back: () -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                Label("Home", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to Home (Esc)")
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .help(statusHelp)
            Text(instance)
                .font(.headline)
            if let checkedAt = alerts?.checkedAt {
                Text("Updated \(timeOrDate(checkedAt))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("The last refresh failed: \(problem.detail)")
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 8)
    }

    private var statusColor: Color {
        switch alerts?.status {
        case .reachable: .green
        case .unreachable(_, .some): .red
        case .unreachable(_, nil), nil: .gray
        }
    }

    private var statusHelp: String {
        switch alerts?.status {
        case .reachable: "Reachable"
        case .unreachable(let error, _): "Unreachable: \(error)"
        case nil: "Loading"
        }
    }
}

extension Severity {
    /// A group's title in an Alertmanager's detail.
    fileprivate var groupTitle: String {
        switch self {
        case .critical: "Critical"
        case .warning: "Warning"
        case .info: "Info"
        case .unknown: "Other"
        }
    }
}
