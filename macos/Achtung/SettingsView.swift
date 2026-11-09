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

struct SettingsView: View {
    @AppStorage(ServerSetting.key) private var serverAddress = ServerSetting.defaultAddress
    @AppStorage(MotionSetting.key) private var animatesDespiteReduceMotion = false
    @State private var draft = ""

    var body: some View {
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
        .onAppear { draft = serverAddress }
    }

    private func apply() {
        guard ServerSetting.url(from: draft) != nil else { return }
        serverAddress = draft.trimmingCharacters(in: .whitespaces)
    }
}
