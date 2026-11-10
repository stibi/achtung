import AchtungAPI
import AchtungDomain
import SwiftUI

/// What the detail's header can do to its alerts at once.
struct AlertmanagerBulkActions {
    /// How many of the listed alerts are unread in Achtung.
    let unread: Int
    let markRead: () -> Void
    /// How many alerts the Silence button covers: the selection, else every active one.
    let silenceCount: Int
    /// Whether that is a selection rather than "all".
    let isSelection: Bool
    let isSilencing: Bool
    /// Asks to silence them for a duration; the detail confirms first.
    let silence: (SilenceDuration) -> Void
}

/// Back to Home, the Alertmanager with its status dot, when it was read, and a reload; then
/// Mark as Read and the Silence button, as a channel has them.
struct AlertmanagerHeader: View {
    let instance: String
    let alerts: AlertmanagerAlerts?
    let problem: ServerError?
    let bulk: AlertmanagerBulkActions
    let back: () -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                Label("Home", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to Home (Esc)")
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .help(statusHelp)
            Text(instance)
                .font(.headline)
            if let checkedAt = alerts?.checkedAt {
                Text("Updated \(timeOrDate(checkedAt))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("The last refresh failed: \(problem.detail)")
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
            .accessibilityLabel("Refresh")
            Button(action: bulk.markRead) {
                Label("Mark as Read", systemImage: "checkmark.circle")
                    .labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
            .disabled(bulk.unread == 0)
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .help("Mark the listed alerts read in Achtung (⇧⌘K)")
            silenceMenu
        }
        .padding(.horizontal, 8)
    }

    private var silenceMenu: some View {
        Menu {
            ForEach(SilenceDuration.allCases) { option in
                Button("For \(option.title)…") { bulk.silence(option) }
            }
        } label: {
            Label(silenceTitle, systemImage: "bell.slash")
                .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .fixedSize()
        // The server takes 500 at a time.
        .disabled(bulk.silenceCount == 0 || bulk.silenceCount > 500 || bulk.isSilencing)
        .help(
            bulk.isSelection
                ? "Silence the selected alerts, each with its own Alertmanager silence"
                : "Silence every active alert here, each with its own Alertmanager silence. "
                    + "Select alerts to silence only those.")
    }

    private var silenceTitle: String {
        if bulk.isSilencing {
            "Silencing…"
        } else if bulk.isSelection {
            "Silence \(bulk.silenceCount) Selected…"
        } else {
            "Silence All…"
        }
    }

    private var statusColor: Color {
        switch alerts?.status {
        case .reachable: .green
        case .unreachable(_, .some): .red
        case .unreachable(_, nil), nil: .gray
        }
    }

    private var statusHelp: String {
        switch alerts?.status {
        case .reachable: "Reachable"
        case .unreachable(let error, _): "Unreachable: \(error)"
        case nil: "Loading"
        }
    }
}

/// A note above an Alertmanager's alerts: a problem, or what silencing came to.
struct Banner: Equatable {
    let text: String
    let isProblem: Bool

    static func problem(_ text: String) -> Banner { Banner(text: text, isProblem: true) }

    /// What silencing came to (`AlertSilenceResult.summary`).
    init(results: [AlertSilenceResult], titles: [String: String]) {
        let summary = AlertSilenceResult.summary(of: results, titles: titles)
        self.init(text: summary.text, isProblem: summary.failed)
    }

    init(text: String, isProblem: Bool) {
        self.text = text
        self.isProblem = isProblem
    }
}

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    var body: some View {
        let tint: Color = banner.isProblem ? .orange : .green
        HStack(alignment: .firstTextBaseline) {
            Label(
                banner.text,
                systemImage: banner.isProblem ? "exclamationmark.triangle.fill" : "bell.slash.fill"
            )
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}
