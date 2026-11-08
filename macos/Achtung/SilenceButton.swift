import AchtungAPI
import AchtungDomain
import SwiftUI

/// Silences an occurrence's alert for a duration (ADR 0008). Returns why it failed, if it
/// did; on success the model shows the silenced occurrence everywhere.
typealias SilenceAction = @MainActor (Occurrence, SilenceDuration) async -> ServerError?

/// A split button: "Silence 4h" silences for the remembered duration; its arrow offers
/// every duration, and the one picked silences the alert and becomes the new default.
/// A silenced alert shows "Silenced" instead: expiring a silence is Alertmanager's job.
struct SilenceButton: View {
    static let warning =
        "Creates an Alertmanager silence for exactly this alert. It mutes the alert for every "
        + "receiver of that Alertmanager (Teams, pager), not only in Achtung."

    let occurrence: Occurrence
    let isSilenced: Bool
    let silence: SilenceAction

    @AppStorage("silenceDuration") private var duration: SilenceDuration = .oneHour
    @State private var isSilencing = false
    @State private var problem: ServerError?

    var body: some View {
        if isSilenced, let until = occurrence.silencedUntil {
            Label("Silenced", systemImage: "bell.slash.fill")
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: .rect(cornerRadius: 6))
                .help(
                    "Silenced in Alertmanager until \(timeOrDate(until)). "
                        + "Expire it in Alertmanager.")
        } else {
            HStack(spacing: 8) {
                Menu {
                    ForEach(SilenceDuration.allCases) { option in
                        Button("Silence for \(option.title)") {
                            duration = option
                            start(option)
                        }
                    }
                } label: {
                    Label(
                        isSilencing ? "Silencing…" : "Silence \(duration.title)",
                        systemImage: "bell.slash")
                } primaryAction: {
                    start(duration)
                }
                .fixedSize()
                .disabled(isSilencing)
                .help(Self.warning)
                if let problem {
                    Label(problem.detail, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help(problem.title)
                }
            }
        }
    }

    /// One silence at a time: the button counts as busy from the click, not from when the
    /// task gets to run, so a quick second click doesn't create a second silence.
    private func start(_ duration: SilenceDuration) {
        guard !isSilencing else { return }
        isSilencing = true
        problem = nil
        Task {
            problem = await silence(occurrence, duration)
            isSilencing = false
        }
    }
}

/// Shows `content` with whether the occurrence is silenced. While it has a silence, it
/// checks again every 10 seconds, so a silence that runs out between refreshes stops
/// showing soon after it ends. (A schedule for the end time alone didn't fire reliably.)
struct SilenceState<Content: View>: View {
    let occurrence: Occurrence
    @ViewBuilder let content: (_ isSilenced: Bool) -> Content

    var body: some View {
        if occurrence.silencedUntil != nil {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                content(occurrence.isSilenced(at: context.date))
            }
        } else {
            content(false)
        }
    }
}

/// "Silenced until 15:30" in the alert header, while a silence mutes it.
struct SilencedPill: View {
    let until: Date

    var body: some View {
        Label("Silenced until \(timeOrDate(until))", systemImage: "bell.slash.fill")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .background(.quaternary, in: Capsule())
    }
}
