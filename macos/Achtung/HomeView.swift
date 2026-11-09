import AchtungAPI
import AchtungDomain
import AppKit
import SwiftUI

/// Home: each Alertmanager as a tile (`AlertmanagerTile`) in an adaptive grid, then the
/// silences ending soon, the noisiest and the longest firing alerts (`HomeSections`). The
/// counts come from each Alertmanager itself, through the server, which reads them at
/// most every 30 seconds; Home asks as often while it's on screen, and not at all while
/// the app is hidden or covered.
struct HomeView: View {
    private static let refreshInterval = Duration.seconds(30)

    let model: InboxModel
    /// Shows an occurrence in its channel.
    let open: (Occurrence) -> Void

    var body: some View {
        content
            .navigationTitle("Home")
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HomeHeader(updated: model.homeUpdated, problem: model.homeProblem) {
                        Task { await model.refreshHome() }
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .task {
                while !Task.isCancelled {
                    if NSApp.occlusionState.contains(.visible) {
                        await model.refreshHome()
                    }
                    do {
                        try await Task.sleep(for: Self.refreshInterval)
                    } catch {
                        return  // Cancelled: Home was left or the window closed.
                    }
                }
            }
            // Back on screen: catch up right away rather than at the next tick.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didChangeOcclusionStateNotification)
            ) { _ in
                if NSApp.occlusionState.contains(.visible) {
                    Task { await model.refreshHome() }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let home = model.home {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if home.alertmanagers.isEmpty {
                        ContentUnavailableView(
                            "No Alertmanagers", systemImage: "server.rack",
                            description: Text("The server has none configured."))
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: 16, alignment: .top)],
                        spacing: 16
                    ) {
                        ForEach(home.alertmanagers) { overview in
                            AlertmanagerTile(overview: overview, open: open)
                        }
                    }
                    HomeSections(home: home, open: open)
                }
                .padding(24)
            }
        } else if let problem = model.homeProblem {
            UnreachableView(problem: problem, baseURL: model.baseURL) {
                Task { await model.refreshHome() }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Home's title, when it last loaded, and a button to load it now.
private struct HomeHeader: View {
    let updated: Date?
    let problem: ServerError?
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Home")
                .font(.headline)
            if let updated {
                Text("Updated \(timeOrDate(updated))")
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
}
