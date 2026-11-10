import AchtungDomain
import AppKit
@preconcurrency import UserNotifications

/// What the user did with a notification, handed to `AppModel`.
enum NotificationAction: Sendable, Equatable {
    /// Clicked: open the alert, or for a summary its channel or Live.
    case open
    case markRead
    case silence(SilenceDuration)
}

/// Posts Achtung's macOS notifications (ADR 0013) and passes what the user does with them
/// back: one per alert, or one summary, each with its actions under "Options": Mark as Read
/// and Silence 1h … 1w, the same silence as the in-app button; a summary has Mark All as
/// Read. A notification is identified by its occurrence (`occurrence-<id>`), so a resend
/// replaces the old one, and reading the alert anywhere removes it.
@MainActor
final class AlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let alertCategory = "alert"
    private nonisolated static let summaryCategory = "summary"
    private nonisolated static let markReadAction = "markRead"
    private nonisolated static let silencePrefix = "silence-"

    /// Called with the action, the occurrence ids and the server they belong to.
    var handle: (NotificationAction, [Int], String?) -> Void = { _, _, _ in }

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
        let markRead = UNNotificationAction(identifier: Self.markReadAction, title: "Mark as Read")
        let silences = SilenceDuration.allCases.map {
            UNNotificationAction(
                identifier: Self.silencePrefix + $0.rawValue, title: "Silence \($0.title)")
        }
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.alertCategory, actions: [markRead] + silences,
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Self.summaryCategory,
                actions: [
                    UNNotificationAction(identifier: Self.markReadAction, title: "Mark All as Read")
                ],
                intentIdentifiers: []),
        ])
    }

    /// Per server and occurrence, so a resend replaces the old notification and another
    /// server's alert with the same id is left alone.
    nonisolated static func identifier(of occurrenceID: Int, server: URL) -> String {
        "\(server.absoluteString)#occurrence-\(occurrenceID)"
    }

    /// Asks macOS for permission the first time notifications are on; afterwards macOS
    /// remembers the answer and doesn't ask again.
    func requestAuthorizationIfNeeded() async {
        guard await center.notificationSettings().authorizationStatus == .notDetermined else {
            return
        }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Settings shows what macOS decided; this is only for whoever reads the log.
            print("Achtung couldn't ask for notification permission: \(error.localizedDescription)")
        }
    }

    func post(_ delivery: NotificationDelivery, server: URL) {
        switch delivery {
        case .each(let occurrences):
            for occurrence in occurrences {
                post(occurrence, server: server)
            }
        case .summary(let occurrences):
            let content = UNMutableNotificationContent()
            content.title = AlertNotificationPlan.summaryTitle(of: occurrences)
            content.body = AlertNotificationPlan.summaryBody(of: occurrences)
            content.sound = .default
            content.categoryIdentifier = Self.summaryCategory
            content.threadIdentifier = "summary"
            content.userInfo = [
                "occurrences": occurrences.map(\.id), "server": server.absoluteString,
            ]
            add(
                UNNotificationRequest(
                    identifier: "summary-\(UUID())", content: content, trigger: nil))
        }
    }

    /// A short note that something done from a notification didn't work.
    func postProblem(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        add(UNNotificationRequest(identifier: "problem-\(UUID())", content: content, trigger: nil))
    }

    /// Removes the delivered notifications of these occurrences, e.g. once they're read.
    nonisolated static func removeDelivered(_ occurrenceIDs: [Int], server: URL) {
        guard !occurrenceIDs.isEmpty, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: occurrenceIDs.map { identifier(of: $0, server: server) })
    }

    private func post(_ occurrence: Occurrence, server: URL) {
        let content = UNMutableNotificationContent()
        content.title = occurrence.alert.title
        content.subtitle = "\(occurrence.channel.instance) · #\(occurrence.channel.slug)"
        content.body = occurrence.alert.summary ?? ""
        content.sound = .default
        content.categoryIdentifier = Self.alertCategory
        content.threadIdentifier = "\(occurrence.channel.instance)/\(occurrence.channel.slug)"
        content.userInfo = ["occurrences": [occurrence.id], "server": server.absoluteString]
        add(
            UNNotificationRequest(
                identifier: Self.identifier(of: occurrence.id, server: server), content: content,
                trigger: nil))
    }

    private func add(_ request: UNNotificationRequest) {
        center.add(request) { error in
            if let error {
                print("Achtung couldn't post a notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Banners also while Achtung is the active app: the window may be on another list.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let ids = info["occurrences"] as? [Int] ?? []
        let server = info["server"] as? String
        let identifier = response.actionIdentifier
        let request = response.notification.request.identifier
        let action: NotificationAction? =
            switch identifier {
            case UNNotificationDefaultActionIdentifier: .open
            case Self.markReadAction: .markRead
            default:
                identifier.hasPrefix(Self.silencePrefix)
                    ? SilenceDuration(
                        rawValue: String(identifier.dropFirst(Self.silencePrefix.count))
                    )
                    .map { .silence($0) }
                    : nil
            }
        guard let action else { return }
        await MainActor.run {
            if action == .markRead, request.hasPrefix("summary-") {
                center.removeDeliveredNotifications(withIdentifiers: [request])
            }
            handle(action, ids, server)
        }
    }
}
