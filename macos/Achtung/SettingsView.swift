import SwiftUI

enum ServerSetting {
    static let key = "serverAddress"
    static let defaultAddress = "https://achtung.onprem.agrp.dev"

    /// An http(s) URL with a host, or nil.
    static func url(from address: String) -> URL? {
        guard
            let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
            ["http", "https"].contains(url.scheme), url.host() != nil
        else {
            return nil
        }
        return url
    }
}

/// Whether Achtung's own animation (the krysa's coffee break in Live) plays even when
/// Reduce Motion is on in System Settings. Off by default: the app follows the system.
enum MotionSetting {
    static let key = "animatesDespiteReduceMotion"
}

/// The app's settings: General, kept on this Mac, and Ignored Alerts, kept on the server
/// for every user.
struct SettingsView: View {
    @AppStorage(ServerSetting.key) private var serverAddress = ServerSetting.defaultAddress
    @AppStorage(MotionSetting.key) private var animatesDespiteReduceMotion = false
    @State private var draft = ""

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                general
            }
            Tab("Ignored Alerts", systemImage: "eye.slash") {
                Group {
                    if let url = ServerSetting.url(from: serverAddress) {
                        // A new server has its own list.
                        IgnoredAlertsSettings(baseURL: url).id(url)
                    } else {
                        Text("Set a valid server address in General first.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(width: 440)
            }
        }
    }

    private var general: some View {
        Form {
            TextField("Server", text: $draft, prompt: Text(ServerSetting.defaultAddress))
                .onSubmit(apply)
            Text("The Achtung server's base URL, e.g. http://achtung.internal:8080.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Apply", action: apply)
                    .disabled(ServerSetting.url(from: draft) == nil || draft == serverAddress)
                    .keyboardShortcut(.defaultAction)
            }
            Divider()
                .padding(.vertical, 6)
            Toggle("Animate even when Reduce Motion is on", isOn: $animatesDespiteReduceMotion)
            Text(
                "The krysa's coffee break in Live moves although Reduce Motion is on in "
                    + "System Settings. When off, Achtung follows the system."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
        // Once per window, not on every return to this tab, so an address being typed
        // survives a look at the other tab; an applied one replaces it.
        .onAppear { if draft.isEmpty { draft = serverAddress } }
        .onChange(of: serverAddress) { draft = serverAddress }
    }

    private func apply() {
        guard ServerSetting.url(from: draft) != nil else { return }
        serverAddress = draft.trimmingCharacters(in: .whitespaces)
    }
}
