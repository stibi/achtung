import AchtungAPI
import AchtungDomain
import AppKit
import Foundation

/// The app's settings for macOS notifications (ADR 0013), kept on this Mac.
enum NotificationSetting {
    static let enabledKey = "notificationsEnabled"
    static let criticalKey = "notifyCritical"
    static let warningKey = "notifyWarning"
    /// Paused until this time (seconds since the reference date); 0 when not paused.
    static let pausedUntilKey = "notificationsPausedUntil"

    static func severities(in defaults: UserDefaults) -> Set<Severity> {
        var severities: Set<Severity> = []
        if defaults.object(forKey: criticalKey) as? Bool ?? true {
            severities.insert(.critical)
        }
        if defaults.bool(forKey: warningKey) {
            severities.insert(.warning)
        }
        return severities
    }

    static func isOn(in defaults: UserDefaults, at now: Date) -> Bool {
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let pausedUntil = Date(
            timeIntervalSinceReferenceDate: defaults.double(forKey: pausedUntilKey))
        return enabled && pausedUntil <= now
    }
}

/// The app's one connection to the server, alive with or without a window (ADR 0013): the
/// inbox (`InboxModel`), refreshed every 30 seconds, and the notifications it brings. The
/// window and the menu bar read the inbox; neither owns the refreshing.
@Observable @MainActor
final class AppModel {
    private static let refreshInterval = Duration.seconds(30)
    /// The ignored alert names are read again after this long, or when they change.
    private static let ignoredNamesAge: TimeInterval = 300

    /// Nil while the server address is invalid.
    private(set) var inbox: InboxModel?
    /// The server's ignored alert names, which neither notify nor count in the menu bar.
    private(set) var ignoredNames: Set<String> = []
    /// Opens the main window; set by the menu bar's label, which has SwiftUI's `openWindow`.
    var openMainWindow: () -> Void = {}

    private let notifier = AlertNotifier()
    private let defaults: UserDefaults
    private var poller: Task<Void, Never>?
    /// The connection's baseline and what it announced (`AlertNotificationState`).
    private var notifications = AlertNotificationState()
    private var ignoredNamesRead: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifier.handle = { [weak self] action, ids, server in
            self?.handle(action, ids: ids, server: server)
        }
        NotificationCenter.default.addObserver(
            forName: .ignoredAlertNamesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ignoredNamesRead = nil }
        }
    }

    /// Firing critical alerts that are unread, unsilenced and not ignored: the menu bar's
    /// count and list. Nil before the first refresh.
    var unreadCritical: [Occurrence]? {
        guard let inbox, inbox.lastUpdated != nil else { return nil }
        return inbox.unreadCritical.filter {
            !($0.alert.labels["alertname"].map(ignoredNames.contains) ?? false)
        }
    }

    /// Connects to the server at `url`, unless it's connected already: a new inbox and a
    /// new baseline.
    func connect(to url: URL?) {
        guard inbox?.baseURL != url else { return }
        poller?.cancel()
        notifications = AlertNotificationState()
        ignoredNamesRead = nil
        ignoredNames = []
        guard let url else {
            inbox = nil
            return
        }
        let inbox = InboxModel(baseURL: url, defaults: defaults)
        // Bound to this inbox: a refresh of a server left behind mustn't touch the new one's
        // baseline.
        inbox.onRefreshed = { [weak self, weak inbox] in
            if let inbox {
                self?.notify(for: inbox)
            }
        }
        self.inbox = inbox
        poller = Task { [weak self] in await self?.poll() }
        Task { await requestAuthorizationIfOn() }
    }

    /// Asks macOS for permission when notifications are on and it never asked.
    func requestAuthorizationIfOn() async {
        if defaults.object(forKey: NotificationSetting.enabledKey) as? Bool ?? true {
            await notifier.requestAuthorizationIfNeeded()
        }
    }

    /// Shows the window on this alert, or this list.
    func open(_ request: OpenRequest) {
        inbox?.openRequest = request
        showWindow()
    }

    /// Brings the one main window back, also from the Dock, or opens it.
    func showWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: \.isMainAchtungWindow) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow()
        }
    }

    // MARK: - Refreshing

    /// Every 30 seconds, with or without a window. A window's own refresh (opening a list,
    /// coming back to the app) counts, so this skips a refresh that just happened.
    private func poll() async {
        while !Task.isCancelled {
            if let inbox, inbox.lastUpdated.map({ Date.now.timeIntervalSince($0) > 20 }) ?? true {
                await refreshIgnoredNames()
                let scope = inbox.activeScope
                await inbox.refresh(scope, visiting: NSApp.isActive && scope != nil)
            }
            do {
                try await Task.sleep(for: Self.refreshInterval)
            } catch {
                return
            }
        }
    }

    private func refreshIgnoredNames() async {
        guard let inbox,
            ignoredNamesRead.map({ Date.now.timeIntervalSince($0) > Self.ignoredNamesAge }) ?? true
        else { return }
        let ignored = inbox.homeModel.ignoredAlerts
        await ignored.reload()
        if let names = ignored.names, inbox === self.inbox {
            ignoredNames = Set(names)
            ignoredNamesRead = .now
        }
    }

    // MARK: - Notifying

    /// After each refresh of the current inbox: what `AlertNotificationState` says to
    /// announce.
    private func notify(for refreshed: InboxModel) {
        guard refreshed === inbox else { return }
        let now = Date.now
        let rules = NotificationRules(
            severities: NotificationSetting.severities(in: defaults), ignoredNames: ignoredNames)
        let notifying = notifications.refreshed(
            feed: refreshed.feed, isOn: NotificationSetting.isOn(in: defaults, at: now),
            rules: rules, readState: refreshed.readState, now: now)
        guard !notifying.isEmpty else { return }
        notifier.post(AlertNotificationPlan.delivery(of: notifying), server: refreshed.baseURL)
    }

    private func handle(_ action: NotificationAction, ids: [Int], server: String?) {
        guard let inbox, server == inbox.baseURL.absoluteString else {
            // A notification from a server Achtung has since left: say so rather than
            // pretend it worked.
            if action == .open {
                showWindow()
            } else {
                notifier.postProblem(
                    title: "Couldn't do that",
                    body: "Achtung is connected to another server now.")
            }
            return
        }
        switch action {
        case .open:
            Task { await open(ids, in: inbox) }
        case .markRead:
            Task { await markRead(ids, in: inbox) }
        case .silence(let duration):
            Task { await silence(ids, for: duration, in: inbox) }
        }
    }

    /// One alert opens in its channel; a summary opens their channel, or Live.
    private func open(_ ids: [Int], in inbox: InboxModel) async {
        var found: [Occurrence] = []
        for id in ids {
            if let occurrence = try? await inbox.occurrence(withID: id) {
                found.append(occurrence)
            }
        }
        if ids.count == 1, let occurrence = found.first {
            open(.occurrence(occurrence))
            return
        }
        let channels = Set(found.map(\.channel))
        let channel = channels.count == 1 ? channels.first : nil
        open(.list(channel.map { .channel($0) } ?? .allChannels))
    }

    private func markRead(_ ids: [Int], in inbox: InboxModel) async {
        for id in ids {
            do throws(ServerError) {
                inbox.markRead(try await inbox.occurrence(withID: id))
            } catch {
                notifier.postProblem(title: "Couldn't mark the alert read", body: error.detail)
            }
        }
    }

    /// The same silence as the alert's button (ADR 0008); a failure gets a notification.
    private func silence(_ ids: [Int], for duration: SilenceDuration, in inbox: InboxModel) async {
        for id in ids {
            do throws(ServerError) {
                let occurrence = try await inbox.occurrence(withID: id)
                if let problem = await inbox.silence(occurrence, for: duration) {
                    notifier.postProblem(
                        title: "Couldn't silence \(occurrence.alert.title)", body: problem.detail)
                } else {
                    AlertNotifier.removeDelivered([id], server: inbox.baseURL)
                }
            } catch {
                notifier.postProblem(title: "Couldn't silence the alert", body: error.detail)
            }
        }
    }
}

extension NSWindow {
    /// The main window (the inbox), not Settings or the menu bar's, also while minimised.
    var isMainAchtungWindow: Bool {
        identifier?.rawValue.hasPrefix(AchtungApp.mainWindowID) == true
            && (isVisible || isMiniaturized)
    }
}
