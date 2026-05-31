import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) var dismiss

    var onShowGettingStarted: (() -> Void)? = nil

    @State private var apiURL: String = ""
    @State private var editingClientId = false
    @State private var clientIdDraft = ""
    @State private var clientIdError = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            Form {
                if let show = onShowGettingStarted {
                    Section {
                        Button {
                            show()
                        } label: {
                            Label("Show Getting Started…", systemImage: "sparkles")
                        }
                    }
                }

                Section("Server") {
                    TextField("API base URL", text: $apiURL, prompt: Text("https://api.odit.example.com"))
                        .textFieldStyle(.roundedBorder)
                }

                Section("Device") {
                    if editingClientId {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("New device ID")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("00000000-0000-0000-0000-000000000000", text: $clientIdDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .onSubmit(submitClientIdEdit)
                            if !clientIdError.isEmpty {
                                Text(clientIdError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Text("Replaces the local UUID and resets the sync cursor so the next Load re-evaluates everything against this identity. Use this to recover a UUID you've already linked on the web.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            HStack {
                                Button("Save", action: submitClientIdEdit)
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(clientIdDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Cancel") { cancelClientIdEdit() }
                            }
                        }
                    } else {
                        LabeledContent("Device ID") {
                            Text(settings.clientId)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(settings.clientId, forType: .string)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            Button {
                                clientIdDraft = settings.clientId
                                clientIdError = ""
                                editingClientId = true
                            } label: {
                                Label("Change…", systemImage: "pencil")
                            }
                        }
                        Text("Saved in Keychain, UserDefaults, and at \(DeviceIdentity.humanReadablePath) so it survives uninstalls and prefs deletion.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Sync") {
                    LabeledContent("Last synced ROWID") {
                        Text(String(settings.lastSyncedRowId))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button("Reset cursor (re-load all)") {
                        settings.resetCursor()
                    }
                    .foregroundStyle(.red)
                }

            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 560)
        .onAppear {
            apiURL = settings.apiBaseURL
        }
    }

    private func save() {
        settings.apiBaseURL = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }

    private func submitClientIdEdit() {
        let raw = clientIdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if settings.setClientId(raw) {
            editingClientId = false
            clientIdError = ""
        } else {
            clientIdError = "Not a valid UUID. Expected 36 chars like xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx."
        }
    }

    private func cancelClientIdEdit() {
        editingClientId = false
        clientIdDraft = ""
        clientIdError = ""
    }
}

struct LogsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if state.logs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No log entries yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.logs) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 76, alignment: .leading)
                        levelBadge(entry.level)
                        Text(entry.message)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 640, height: 480)
    }

    @ViewBuilder private func levelBadge(_ level: SyncLogEntry.Level) -> some View {
        switch level {
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.blue)
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
