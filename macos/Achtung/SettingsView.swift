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

struct SettingsView: View {
    @AppStorage(ServerSetting.key) private var serverAddress = ServerSetting.defaultAddress
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
