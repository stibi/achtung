import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// Settings' Notifications tab: whether Achtung posts macOS notifications, for which
/// severities, and whether macOS lets it.
struct NotificationSettings: View {
    let app: AppModel

    @AppStorage(NotificationSetting.enabledKey) private var enabled = true
    @AppStorage(NotificationSetting.criticalKey) private var critical = true
    @AppStorage(NotificationSetting.warningKey) private var warning = false
    @AppStorage(NotificationSetting.pausedUntilKey) private var pausedUntil = 0.0
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Form {
            Toggle("Notify about new and resent alerts", isOn: $enabled)
            Text(
                "One notification per alert, or one summary for more than three at once. "
                    + "Not for silenced, read or ignored alerts."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Critical", isOn: $critical)
                .disabled(!enabled)
            Toggle("Warning", isOn: $warning)
                .disabled(!enabled)
            if Date(timeIntervalSinceReferenceDate: pausedUntil) > .now {
                HStack {
                    Text(
                        "Paused until "
                            + Date(timeIntervalSinceReferenceDate: pausedUntil)
                            .formatted(date: .omitted, time: .shortened))
                    Button("Resume") { pausedUntil = 0 }
                }
            }
            if enabled, status == .denied {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "macOS doesn't allow Achtung's notifications.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Button("Open Notification Settings…", action: openSystemSettings)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: enabled) {
            if enabled {
                await app.requestAuthorizationIfOn()
            }
            status = await UNUserNotificationCenter.current().notificationSettings()
                .authorizationStatus
        }
        // Back from System Settings: show the new answer.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task {
                status = await UNUserNotificationCenter.current().notificationSettings()
                    .authorizationStatus
            }
        }
    }

    private func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
