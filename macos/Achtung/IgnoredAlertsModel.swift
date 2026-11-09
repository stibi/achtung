import AchtungAPI
import AchtungDomain
import Foundation

extension Notification.Name {
    /// The server's ignored alert names changed. The object is the `IgnoredAlertsModel`
    /// that saved them; `ignoredAlertNamesServer` says on which server. Home and an
    /// Alertmanager's detail reload at once, and Settings shows a change made elsewhere.
    static let ignoredAlertNamesChanged = Notification.Name("ignoredAlertNamesChanged")
}

extension Notification {
    /// The base URL of the server whose ignored alert names changed.
    var ignoredAlertNamesServer: URL? { userInfo?["baseURL"] as? URL }
}

/// The alert names Home leaves out (`IgnoredAlertNames`): one list on the server, for every
/// user. Settings edits it, and an Alertmanager's detail adds to it. Each change is saved
/// at once, replacing the whole list, so it's built on a fresh read of the list, and one
/// change waits for the one before: a name removed elsewhere, or added a moment ago, isn't
/// lost. The server's answer is the list from then on.
@Observable @MainActor
final class IgnoredAlertsModel {
    /// As the server last returned them, sorted; nil until loaded.
    private(set) var names: [String]?
    /// Why the last load or save failed, e.g. the server's 400; nil once one succeeds.
    private(set) var problem: ServerError?
    private(set) var isSaving = false

    private let server: AchtungServer
    private let baseURL: URL
    /// The latest reload or change, which the next one waits for.
    private var lastChange: Task<Bool, Never>?

    init(baseURL: URL) {
        self.baseURL = baseURL
        server = AchtungServer(baseURL: baseURL)
    }

    /// Reads the list again, after any change still under way, so an older answer never
    /// replaces a newer one.
    func reload() async {
        await enqueue {
            await self.load()
            return self.problem == nil
        }
    }

    private func load() async {
        do throws(ServerError) {
            names = try await server.ignoredAlertNames()
            problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            problem = error
        }
    }

    /// Adds a name, trimmed. False when it wasn't saved: the server refused it or couldn't
    /// be reached (see `problem`). True also when it was there already.
    @discardableResult
    func add(_ name: String) async -> Bool {
        await change { names in IgnoredAlertNames.adding(name, to: names) }
    }

    func remove(_ removed: Set<String>) async {
        await change { names in
            names.contains(where: removed.contains) ? names.filter { !removed.contains($0) } : nil
        }
    }

    /// Reads the list, applies `edit` (nil: nothing to change) and saves the result.
    @discardableResult
    private func change(_ edit: @escaping ([String]) -> [String]?) async -> Bool {
        await enqueue {
            self.isSaving = true
            defer { self.isSaving = false }
            await self.load()
            guard self.problem == nil, let names = self.names else { return false }
            guard let edited = edit(names) else { return true }
            return await self.save(edited)
        }
    }

    /// Runs `work` after the reload or change before it.
    @discardableResult
    private func enqueue(_ work: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = lastChange
        let task = Task {
            _ = await previous?.value
            return await work()
        }
        lastChange = task
        return await task.value
    }

    private func save(_ names: [String]) async -> Bool {
        do throws(ServerError) {
            self.names = try await server.setIgnoredAlertNames(names)
            problem = nil
            NotificationCenter.default.post(
                name: .ignoredAlertNamesChanged, object: self, userInfo: ["baseURL": baseURL])
            return true
        } catch {
            problem = error
            return false
        }
    }
}
