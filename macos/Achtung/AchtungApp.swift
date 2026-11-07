import SwiftUI

@main
struct AchtungApp: App {
    @AppStorage(ServerSetting.key) private var serverAddress = ServerSetting.defaultAddress

    var body: some Scene {
        WindowGroup {
            Group {
                if let url = ServerSetting.url(from: serverAddress) {
                    // A new address starts a fresh inbox for that server.
                    InboxView(baseURL: url).id(url)
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
        Settings {
            SettingsView()
        }
    }
}
