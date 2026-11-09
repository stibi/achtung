import AchtungAPI
import AchtungDomain
import Foundation

/// What Home shows: the tiles and lists (`home`), and an Alertmanager's alerts for its
/// detail. Apart from the inbox's state: only Home refreshes it. `InboxModel` makes it with
/// the same server, so the views still never talk to the server themselves.
@Observable @MainActor
final class HomeModel {
    /// Nil until it first loads.
    private(set) var home: Home?
    /// Why the last Home refresh failed; nil once one succeeds again.
    private(set) var homeProblem: ServerError?
    private(set) var homeUpdated: Date?
    /// Each Alertmanager's alerts, by instance, as last loaded for its detail.
    private(set) var alertmanagerAlerts: [String: AlertmanagerAlerts] = [:]
    /// Why an Alertmanager's alerts last failed to load, by instance.
    private(set) var alertmanagerProblems: [String: ServerError] = [:]

    /// The alert names Home leaves out, which a detail's alert row can add to.
    let ignoredAlerts: IgnoredAlertsModel

    private let server: AchtungServer

    init(server: AchtungServer, baseURL: URL) {
        self.server = server
        ignoredAlerts = IgnoredAlertsModel(baseURL: baseURL)
    }

    /// Reloads the Home view: the server reads each Alertmanager at most every 30 seconds.
    func refreshHome() async {
        do throws(ServerError) {
            home = try await server.home()
            homeProblem = nil
            homeUpdated = .now
        } catch {
            guard !Task.isCancelled else { return }
            homeProblem = error
        }
    }

    /// Reloads one Alertmanager's alerts for its detail, from the server's cached read.
    func refreshAlerts(of instance: String) async {
        do throws(ServerError) {
            alertmanagerAlerts[instance] = try await server.alertmanagerAlerts(instance: instance)
            alertmanagerProblems[instance] = nil
        } catch {
            guard !Task.isCancelled else { return }
            alertmanagerProblems[instance] = error
        }
    }

    /// An occurrence by id, to open it from a list that knows only its id.
    func occurrence(id: Int) async throws(ServerError) -> Occurrence {
        try await server.occurrence(id: id).occurrence
    }
}
