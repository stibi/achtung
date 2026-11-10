import AppKit
import SwiftUI

@main
struct AchtungApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(ServerSetting.key) private var serverAddress = ServerSetting.defaultAddress
    /// The connection to the server, with or without a window (ADR 0013).
    @State private var app: AppModel

    init() {
        let app = AppModel()
        app.connect(
            to: ServerSetting.url(
                from: UserDefaults.standard.string(forKey: ServerSetting.key)
                    ?? ServerSetting.defaultAddress))
        _app = State(initialValue: app)
    }

    var body: some Scene {
        // One window: notifications and the menu bar bring it back rather than opening more.
        Window("Achtung", id: Self.mainWindowID) {
            Group {
                if let inbox = app.inbox {
                    // A new address starts a fresh inbox for that server.
                    InboxView(model: inbox) { app.viewing($0, on: inbox.baseURL) }
                        .id(inbox.baseURL)
                } else {
                    ContentUnavailableView {
                        Label("Invalid server address", systemImage: "link.badge.plus")
                    } description: {
                        Text(serverAddress)
                    } actions: {
                        SettingsLink {
                            Text("Change Server…")
                        }
                    }
                }
            }
            .frame(minWidth: 900, minHeight: 500)
        }
        .onChange(of: serverAddress) {
            app.connect(to: ServerSetting.url(from: serverAddress))
        }
        Settings {
            SettingsView(app: app)
        }
        MenuBarExtra {
            MenuBarMenu(app: app)
        } label: {
            MenuBarLabel(app: app)
        }
    }
}

/// Closing the last window leaves Achtung running in the menu bar, refreshing and
/// notifying (ADR 0013).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
