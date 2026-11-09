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

    private static let padding: CGFloat = 24
    private static let spacing: CGFloat = 24

    let model: InboxModel
    /// Shows an occurrence in its channel.
    let open: (Occurrence) -> Void

    /// The scroll view's size, which is what shows under the toolbar; the window sets it.
    @State private var viewport: CGSize = .zero
    /// The tiles' height, above the sections.
    @State private var tilesHeight: CGFloat = 0
    /// The Alertmanager whose detail is open in place of the tiles, if any.
    @State private var shownInstance: String?
    /// Counts the user's reloads, which collapse expanded sections; the automatic refresh
    /// every 30 seconds doesn't, so a list being read isn't snapped shut.
    @State private var collapseRequest = 0

    /// The room for the sections: the page's width, and the height left under the tiles
    /// so that Home doesn't scroll (a point spare for rounding).
    private var sectionsSpace: CGSize {
        CGSize(
            width: viewport.width - 2 * Self.padding,
            height: viewport.height - 2 * Self.padding - tilesHeight - Self.spacing - 1)
    }

    var body: some View {
        if let shownInstance {
            AlertmanagerDetailView(model: model, instance: shownInstance, open: open) {
                self.shownInstance = nil
            }
        } else {
            home
        }
    }

    private var home: some View {
        content
            .navigationTitle("Home")
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HomeHeader(
                        updated: model.homeModel.homeUpdated, problem: model.homeModel.homeProblem
                    ) {
                        collapseRequest += 1
                        Task { await model.homeModel.refreshHome() }
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .task {
                while !Task.isCancelled {
                    if NSApp.occlusionState.contains(.visible) {
                        await model.homeModel.refreshHome()
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
                    Task { await model.homeModel.refreshHome() }
                }
            }
            // The counts follow a change to the ignored alert names at once.
            .onReceive(
                NotificationCenter.default.publisher(for: .ignoredAlertNamesChanged)
            ) { notification in
                if notification.ignoredAlertNamesServer == model.baseURL {
                    Task { await model.homeModel.refreshHome() }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let home = model.homeModel.home {
            ScrollView {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    tiles(home)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            tilesHeight = $0
                        }
                    HomeSections(
                        home: home, available: sectionsSpace, collapseRequest: collapseRequest,
                        open: open)
                }
                .padding(Self.padding)
            }
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                viewport = $0
            }
        } else if let problem = model.homeModel.homeProblem {
            UnreachableView(problem: problem, baseURL: model.baseURL) {
                Task { await model.homeModel.refreshHome() }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func tiles(_ home: Home) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
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
                    AlertmanagerTile(overview: overview, open: open) {
                        shownInstance = overview.instance
                    }
                }
            }
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
