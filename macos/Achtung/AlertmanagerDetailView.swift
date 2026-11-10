import AchtungAPI
import AchtungDomain
import AppKit
import SwiftUI

/// What an Alertmanager tile opens on Home: its active alerts grouped by severity, most
/// severe first, then its silenced and inhibited ones, folded away. They come from the
/// same read as the tile's counts. Back (or Esc) returns to Home. It reloads every 30
/// seconds while the app is on screen, and on ⌘R; the list scrolls like any other.
///
/// Its header marks the listed alerts read, as a channel's does, and silences alerts:
/// the selected ones, else every active one ("Silence All"), each with its own exact
/// silence (ADR 0016), after a confirmation. Inhibited alerts notify nothing now, so
/// "Silence All" leaves them out; they can be selected.
struct AlertmanagerDetailView: View {
    private static let refreshInterval = Duration.seconds(30)

    let model: InboxModel
    let instance: String
    /// Shows an occurrence in its channel.
    let open: (Occurrence) -> Void
    let back: () -> Void

    /// Why opening an alert's occurrence, or ignoring its name, failed, or what silencing
    /// came to: above the list.
    @State private var banner: Banner?
    /// The alerts picked for silencing, by fingerprint.
    @State private var selection: Set<String> = []
    /// Silencing asked for and waiting for its confirmation.
    @State private var pendingSilence: PendingSilence?
    @State private var isSilencing = false

    private var alerts: AlertmanagerAlerts? { model.homeModel.alertmanagerAlerts[instance] }
    private var problem: ServerError? { model.homeModel.alertmanagerProblems[instance] }

    var body: some View {
        content
            .navigationTitle(instance)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    AlertmanagerHeader(
                        instance: instance, alerts: alerts, problem: problem, bulk: bulk,
                        back: back
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
            .confirmationDialog(
                pendingSilence.map {
                    "Silence \($0.fingerprints.count) "
                        + ($0.fingerprints.count == 1 ? "alert" : "alerts")
                        + " on \(instance) for \($0.duration.title)?"
                } ?? "",
                isPresented: Binding(
                    get: { pendingSilence != nil }, set: { if !$0 { pendingSilence = nil } }),
                presenting: pendingSilence
            ) { pending in
                Button("Silence for \(pending.duration.title)", role: .destructive) {
                    silence(pending)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(
                    "They are muted for every receiver of this Alertmanager, not only in "
                        + "Achtung.")
            }
            // A refresh can take selected alerts away, e.g. silenced elsewhere.
            .onChange(of: alerts) {
                selection.formIntersection(selectable)
            }
            // An ignored name leaves the list at once, wherever it was added.
            .onReceive(
                NotificationCenter.default.publisher(for: .ignoredAlertNamesChanged)
            ) { notification in
                if notification.ignoredAlertNamesServer == model.baseURL {
                    Task { await model.homeModel.refreshAlerts(of: instance) }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let alerts {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // In the content rather than a safe-area inset, which left the window's
                    // columns under the toolbar once it appeared.
                    if let banner {
                        BannerView(banner: banner) { self.banner = nil }
                    }
                    // The "since" times move on every minute between refreshes.
                    TimelineView(.everyMinute) { context in
                        AlertGroups(
                            alerts: alerts, now: context.date,
                            actions: AlertRowActions(
                                open: openOccurrence(id:), ignore: ignore(name:),
                                selection: $selection))
                    }
                }
                .padding(24)
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
        banner = nil
        Task {
            do throws(ServerError) {
                open(try await model.homeModel.occurrence(id: id))
            } catch {
                banner = .problem("Couldn't open the alert: \(error.detail)")
            }
        }
    }

    /// Adds the name to the ignored alert names; the list reloads without it.
    private func ignore(name: String) {
        banner = nil
        Task {
            let ignored = model.homeModel.ignoredAlerts
            if await !ignored.add(name) {
                banner = .problem(
                    "Couldn't ignore \(name): \(ignored.problem?.detail ?? "unknown problem")")
            }
        }
    }

    // MARK: - Mark as Read and Silence

    /// The occurrences behind the listed alerts.
    private var occurrenceIDs: Set<Int> {
        Set(alerts?.alerts.compactMap(\.occurrenceID) ?? [])
    }

    private var selectable: Set<String> {
        Set(alerts?.selectable.map(\.fingerprint) ?? [])
    }

    /// What Silence covers: the selection, else every active alert.
    private var silenceTargets: [String] {
        selection.isEmpty
            ? alerts?.silenceableByDefault.map(\.fingerprint) ?? []
            : alerts?.alerts.map(\.fingerprint).filter(selection.contains) ?? []
    }

    private var bulk: AlertmanagerBulkActions {
        AlertmanagerBulkActions(
            unread: model.unread(ids: occurrenceIDs).count,
            markRead: { model.markRead(ids: occurrenceIDs) },
            silenceCount: silenceTargets.count, isSelection: !selection.isEmpty,
            isSilencing: isSilencing, silence: askToSilence(for:))
    }

    private func askToSilence(for duration: SilenceDuration) {
        pendingSilence = PendingSilence(fingerprints: silenceTargets, duration: duration)
    }

    /// After the confirmation: silences them, then says what didn't work, by alert.
    private func silence(_ pending: PendingSilence) {
        isSilencing = true
        banner = nil
        let titles = Dictionary(
            alerts?.alerts.map { ($0.fingerprint, $0.title) } ?? [],
            uniquingKeysWith: { first, _ in first })
        Task {
            defer { isSilencing = false }
            do throws(ServerError) {
                let results = try await model.homeModel.silenceAlerts(
                    pending.fingerprints, of: instance, for: pending.duration)
                selection = []
                banner = Banner(results: results, titles: titles)
                // The inbox, menu bar and notifications show the new silences now, not at
                // the next refresh.
                await model.refresh(model.activeScope, visiting: false)
            } catch {
                // Only a failure on Alertmanager's side may have left some silences made.
                let partly: Bool =
                    switch error {
                    case .rejected, .notFound: false
                    default: true
                    }
                banner = .problem(
                    "Couldn't silence the alerts: \(error.detail)"
                        + (partly
                            ? ". Some may be silenced; trying again changes their silences "
                                + "rather than adding more." : ""))
            }
        }
    }
}

/// Silencing waiting for its confirmation.
private struct PendingSilence {
    let fingerprints: [String]
    let duration: SilenceDuration
}
