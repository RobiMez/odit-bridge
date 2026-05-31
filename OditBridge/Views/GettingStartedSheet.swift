import SwiftUI

// Surfaced from the Help menu (⌘?) and from a button in the Settings sheet.
// Tailored to people who received a pre-built OditBridge.app from someone
// else (i.e., not their own dev cert) — the Gatekeeper bypass instructions
// only make sense for that audience.
struct GettingStartedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Getting started")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                    step(
                        number: 1,
                        title: "If macOS blocks the app",
                        body: "If you got a \"Apple is not able to verify…\" warning, this build isn't notarized — that's normal for an open-source build signed with someone else's developer cert. **In Finder, right-click OditBridge → Open**, then click \"Open Anyway\" on the dialog that follows. You only have to do this the first time.",
                        action: nil
                    )
                    step(
                        number: 2,
                        title: "Grant Full Disk Access",
                        body: "OditBridge reads bank SMS from ~/Library/Messages/chat.db, which macOS guards behind Full Disk Access. Open System Settings → Privacy & Security → Full Disk Access and add OditBridge.",
                        action: ("Open System Settings", {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        })
                    )
                    step(
                        number: 3,
                        title: "Link this Mac to your odit account",
                        body: "Open the odit web app while signed in, go to Devices → \"Link a Mac\", and paste the Device ID below. The server starts attributing this Mac's uploads to your account.",
                        action: ("Copy device ID", {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(settings.clientId, forType: .string)
                        })
                    )
                    deviceIdRow
                    step(
                        number: 4,
                        title: "Pull and sync your messages",
                        body: "Switch to the Staged tab, click **Load now** to scan chat.db, review what the filter kept, then **Sync now** to upload. Server-parsed transactions show up in the Synced, Charts, and Heatmap views.",
                        action: nil
                    )
                    note
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: 580)
    }

    @ViewBuilder private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to OditBridge")
                .font(.title3.weight(.semibold))
            Text("Four short steps — the rest is the same as the iOS / Android odit clients.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func step(
        number: Int,
        title: String,
        body: String,
        action: (String, () -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                Text(.init(body))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let (label, run) = action {
                    Button(action: run) { Text(label) }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var deviceIdRow: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 40) // align with step text
            Text("Device ID")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(settings.clientId)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder private var note: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
            Text("If your sync history disappears after reinstalling, copy the old Device ID from the web app's Devices page and paste it into Settings → Device → Change… so the server keeps recognising this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}
