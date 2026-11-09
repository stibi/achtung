import AchtungAPI
import SwiftUI

/// Settings' list of ignored alert names, on the server at `baseURL`: add a name with the
/// field (Return or Add), remove the selected ones with − or Delete. Each change is saved
/// at once, and the server's refusal shows below the field.
struct IgnoredAlertsSettings: View {
    let baseURL: URL

    @State private var model: IgnoredAlertsModel
    @State private var draft = ""
    @State private var selection: Set<String> = []

    init(baseURL: URL) {
        self.baseURL = baseURL
        _model = State(initialValue: IgnoredAlertsModel(baseURL: baseURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Alert names left out of Home's counts and lists, for every Achtung user. "
                    + "Exact match on alertname."
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("Channels and Live still show these alerts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let names = model.names {
                editor(names)
            } else if let problem = model.problem {
                loadFailed(problem)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task { await model.reload() }
        // Changed from an Alertmanager's detail: show the server's list. A save here has
        // set the list already.
        .onReceive(NotificationCenter.default.publisher(for: .ignoredAlertNamesChanged)) {
            if $0.ignoredAlertNamesServer == baseURL, $0.object as? IgnoredAlertsModel !== model {
                Task { await model.reload() }
            }
        }
    }

    @ViewBuilder private func editor(_ names: [String]) -> some View {
        VStack(spacing: 0) {
            List(names, id: \.self, selection: $selection) { name in
                Text(name)
            }
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if names.isEmpty {
                    Text("No ignored alert names")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 0) {
                Button(action: removeSelected) {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selection.isEmpty)
                .help("Remove the selected names (Delete)")
                .accessibilityLabel("Remove")
                Spacer()
                if model.isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 6)
                }
            }
            .padding(2)
        }
        .frame(height: 200)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .disabled(model.isSaving)
        HStack {
            TextField("Alert name", text: $draft, prompt: Text("Alert name, e.g. KubeJobFailed"))
                .labelsHidden()
                .onSubmit(add)
            // The field stays enabled while saving, so it keeps the focus for the next
            // name.
            Button("Add", action: add)
                .disabled(
                    model.isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let problem = model.problem {
            Label(problem.detail, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadFailed(_ problem: ServerError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Couldn't load the ignored alert names: \(problem.detail)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                Task { await model.reload() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
    }

    private func add() {
        // Like the disabled Add button: one name at a time, so a refusal stays on screen.
        guard !model.isSaving else { return }
        let name = draft
        Task {
            // A refused name stays in the field, to fix.
            if await model.add(name), draft == name {
                draft = ""
            }
        }
    }

    private func removeSelected() {
        let removed = selection
        Task {
            await model.remove(removed)
            selection.subtract(removed.subtracting(model.names ?? []))
        }
    }
}
