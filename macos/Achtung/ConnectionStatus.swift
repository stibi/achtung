import AchtungAPI
import SwiftUI

extension ServerError {
    var title: String {
        switch self {
        case .unreachable: "Can't reach the server"
        case .invalidResponse: "The server sent something unexpected"
        case .notFound: "Not found"
        case .rejected: "The server rejected a request"
        case .silenceFailed: "Couldn't silence the alert"
        }
    }

    var detail: String {
        switch self {
        case .unreachable(let message), .invalidResponse(let message), .notFound(let message),
            .rejected(let message), .silenceFailed(let message):
            message
        }
    }
}

/// A quiet strip at the bottom of the sidebar while requests fail. What was loaded stays
/// on screen; the next refresh retries.
struct ConnectionBanner: View {
    let problem: ServerError
    let lastUpdated: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(problem.title, systemImage: "exclamationmark.icloud")
                .font(.callout.weight(.medium))
            Group {
                if let lastUpdated {
                    let time = lastUpdated.formatted(date: .omitted, time: .shortened)
                    Text("Retrying. Last update \(time).")
                } else {
                    Text("Retrying.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .help(problem.detail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        .padding(8)
    }
}

/// Shown instead of the inbox when nothing has loaded yet and the server doesn't answer.
struct UnreachableView: View {
    let problem: ServerError
    let baseURL: URL
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(problem.title, systemImage: "exclamationmark.icloud")
        } description: {
            Text("\(baseURL.absoluteString)\n\(problem.detail)")
        } actions: {
            HStack {
                Button("Retry", action: retry)
                SettingsLink {
                    Text("Change Server…")
                }
            }
        }
    }
}
