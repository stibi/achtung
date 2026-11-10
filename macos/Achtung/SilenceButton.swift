import AchtungAPI
import AchtungDomain
import SwiftUI

/// What can be done about an occurrence's silence (ADR 0008, ADR 0015): silence it for a
/// duration from now, which changes its own silence when it has one, or end that silence.
/// Each returns why it failed; on success the model shows the occurrence everywhere.
struct SilenceActions {
    let silence: @MainActor (Occurrence, SilenceDuration) async -> ServerError?
    let unsilence: @MainActor (Occurrence) async -> UnsilenceOutcome

    @MainActor
    init(_ model: InboxModel) {
        silence = { await model.silence($0, for: $1) }
        unsilence = { await model.unsilence($0) }
    }

    init(
        silence: @escaping @MainActor (Occurrence, SilenceDuration) async -> ServerError?,
        unsilence: @escaping @MainActor (Occurrence) async -> UnsilenceOutcome
    ) {
        self.silence = silence
        self.unsilence = unsilence
    }

    /// For previews: nothing happens.
    static let none = SilenceActions(silence: { _, _ in nil }, unsilence: { _ in .ended })
}

/// A split button: "Silence 4h" silences for the remembered duration; its arrow offers
/// every duration, and the one picked silences the alert and becomes the new default.
/// A silenced alert shows "Silenced", a menu that changes the silence to end a duration from
/// now, or ends it (ADR 0015). A broader silence is Alertmanager's to end; when one still
/// mutes the alert afterwards, the button says until when.
struct SilenceButton: View {
    static let warning =
        "Creates an Alertmanager silence for exactly this alert. It mutes the alert for every "
        + "receiver of that Alertmanager (Teams, pager), not only in Achtung."

    let occurrence: Occurrence
    let isSilenced: Bool
    let actions: SilenceActions

    @AppStorage("silenceDuration") private var duration: SilenceDuration = .oneHour
    @State private var isBusy = false
    @State private var problem: ServerError?
    /// "Still silenced until 15:30 by another silence", after ending its own.
    @State private var note: String?

    var body: some View {
        HStack(spacing: 8) {
            if isSilenced, let until = occurrence.silencedUntil {
                Menu {
                    ForEach(SilenceDuration.allCases) { option in
                        Button("Silence for \(option.title) from Now") { start(option) }
                    }
                    Divider()
                    Button("End Silence", action: end)
                } label: {
                    Label(isBusy ? "Changing…" : "Silenced", systemImage: "bell.slash.fill")
                }
                .fixedSize()
                .disabled(isBusy)
                .help(
                    "Silenced in Alertmanager until \(timeOrDate(until)). Change when its own "
                        + "silence ends, or end it; a broader silence is ended in Alertmanager.")
            } else {
                Menu {
                    ForEach(SilenceDuration.allCases) { option in
                        Button("Silence for \(option.title)") {
                            duration = option
                            start(option)
                        }
                    }
                } label: {
                    Label(
                        isBusy ? "Silencing…" : "Silence \(duration.title)",
                        systemImage: "bell.slash")
                } primaryAction: {
                    start(duration)
                }
                .fixedSize()
                .disabled(isBusy)
                .help(Self.warning)
            }
            if let problem {
                Label(problem.detail, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(problem.title)
            } else if let note {
                Label(note, systemImage: "bell.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One change at a time: the button counts as busy from the click, not from when the
    /// task gets to run, so a quick second click doesn't create a second silence.
    private func start(_ duration: SilenceDuration) {
        guard !isBusy else { return }
        isBusy = true
        problem = nil
        note = nil
        Task {
            problem = await actions.silence(occurrence, duration)
            isBusy = false
        }
    }

    private func end() {
        guard !isBusy else { return }
        isBusy = true
        problem = nil
        note = nil
        Task {
            switch await actions.unsilence(occurrence) {
            case .ended: break
            case .stillSilenced(let until):
                note = "Still silenced until \(timeOrDate(until)) by another silence"
            case .failed(let error): problem = error
            }
            isBusy = false
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
