import AchtungDomain
import SwiftUI

/// The menu bar item's icon: a bell, with the count of unread critical alerts beside it
/// when there are any. It also hands `AppModel` the way to open a window.
struct MenuBarLabel: View {
    let app: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let count = app.unreadCritical?.count ?? 0
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
            if count > 0 {
                Text(count.formatted())
            }
        }
        .onAppear {
            app.openMainWindow = { openWindow(id: AchtungApp.mainWindowID) }
        }
        .accessibilityLabel(count > 0 ? "Achtung, \(count) unread critical" : "Achtung")
    }
}

/// The menu bar item's menu: open the app, the newest unread critical alerts, mark them
/// read, pause notifications, quit.
struct MenuBarMenu: View {
    private static let shownAlerts = 5

    let app: AppModel

    @AppStorage(NotificationSetting.pausedUntilKey) private var pausedUntil = 0.0
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open Achtung") { app.showWindow() }
        Divider()
        let unread = app.unreadCritical ?? []
        if app.inbox == nil {
            Text("No valid server address")
        } else if app.unreadCritical == nil {
            Text("Connecting…")
        } else if unread.isEmpty {
            Text("No unread critical alerts")
        } else {
            Section("Unread critical") {
                ForEach(unread.prefix(Self.shownAlerts)) { occurrence in
                    Button(
                        "\(occurrence.alert.title) — \(occurrence.channel.instance) · "
                            + "#\(occurrence.channel.slug)"
                    ) {
                        app.open(.occurrence(occurrence))
                    }
                }
                if unread.count > Self.shownAlerts {
                    Button("\(unread.count - Self.shownAlerts) More in Live…") {
                        app.open(.list(.allChannels))
                    }
                }
            }
            Button("Mark Critical Alerts as Read") {
                for occurrence in unread {
                    app.inbox?.markRead(occurrence)
                }
            }
        }
        Divider()
        if Date(timeIntervalSinceReferenceDate: pausedUntil) > .now {
            Button("Resume Notifications") { pausedUntil = 0 }
        } else {
            Menu("Pause Notifications") {
                Button("For 1 Hour") {
                    pausedUntil = Date.now.addingTimeInterval(3600).timeIntervalSinceReferenceDate
                }
                Button("Until Tomorrow Morning") {
                    // 8:00 tomorrow, not midnight while the user sleeps.
                    let tomorrow = Calendar.current.startOfDay(
                        for: Date.now.addingTimeInterval(24 * 3600))
                    pausedUntil =
                        tomorrow.addingTimeInterval(8 * 3600)
                        .timeIntervalSinceReferenceDate
                }
            }
        }
        // Activated first, or Settings could open behind the app in front.
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Achtung") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
