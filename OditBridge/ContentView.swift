import SwiftUI

enum Sidebar: String, Hashable, CaseIterable, Codable {
    case staged
    case synced
    case charts
    case heatmap

    var label: String {
        switch self {
        case .staged:  return "Staged"
        case .synced:  return "Synced"
        case .charts:  return "Charts"
        case .heatmap: return "Heatmap"
        }
    }

    var systemImage: String {
        switch self {
        case .staged:  return "tray.and.arrow.down"
        case .synced:  return "tray.full"
        case .charts:  return "chart.bar.xaxis"
        case .heatmap: return "calendar"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var state: AppState
    @Environment(\.syncService) private var syncService

    @SceneStorage("sidebarSelection") private var sidebarRaw: String = Sidebar.synced.rawValue
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var showGettingStarted = false

    private var selected: Sidebar { Sidebar(rawValue: sidebarRaw) ?? .synced }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { selected },
                set: { sidebarRaw = ($0 ?? .synced).rawValue }
            )) {
                Section("Data") {
                    ForEach(Sidebar.allCases, id: \.self) { item in
                        Label(item.label, systemImage: item.systemImage).tag(item as Sidebar?)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusFooter()
            }
            .toolbar { toolbarContent }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 920, minHeight: 580)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(onShowGettingStarted: {
                showSettings = false
                showGettingStarted = true
            }).environmentObject(settings)
        }
        .sheet(isPresented: $showLogs) {
            LogsSheet().environmentObject(state)
        }
        .sheet(isPresented: $showGettingStarted) {
            GettingStartedSheet().environmentObject(settings)
        }
        .task(id: selected) {
            if selected == .synced
                && state.syncedTransactions.isEmpty
                && !state.syncedLoading {
                await syncService?.fetchSynced()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .oditShowGettingStarted)) { _ in
            showGettingStarted = true
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch selected {
        case .staged:
            StagedView()
        case .synced:
            SyncedView(onRefresh: { Task { await syncService?.fetchSynced() } })
        case .charts:
            ChartsView()
        case .heatmap:
            HeatmapView(sidebar: $sidebarRaw)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showLogs = true } label: { Image(systemName: "list.bullet.rectangle") }
                .help("Logs")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("Settings")
        }
    }
}

// Slim macOS-style status bar across the bottom of the detail column. Shows
// sync state + last-sync timestamp + an inline progress bar when uploading.
struct StatusFooter: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: Settings

    var body: some View {
        HStack(spacing: 10) {
            statusPill
            Spacer()
            if case let .syncing(uploaded, total) = state.status, total > 0 {
                ProgressView(value: Double(uploaded), total: Double(total))
                    .frame(width: 110)
            }
            if let last = settings.lastSyncDate {
                Text("Last sync \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    @ViewBuilder private var statusPill: some View {
        switch state.status {
        case .idle:
            Label("Idle", systemImage: "circle.dashed")
                .foregroundStyle(.secondary).font(.caption)
                .labelStyle(.titleAndIcon)
        case .loading:
            Label("Scanning chat.db…", systemImage: "magnifyingglass")
                .foregroundStyle(.blue).font(.caption)
                .labelStyle(.titleAndIcon)
        case .syncing(let uploaded, let total):
            Label(total > 0 ? "Syncing \(uploaded)/\(total)" : "Syncing \(uploaded)…",
                  systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue).font(.caption)
                .labelStyle(.titleAndIcon)
        case .ok:
            Label("Connected", systemImage: "circle.fill")
                .foregroundStyle(.green).font(.caption)
                .labelStyle(.titleAndIcon)
        case .noPermission:
            Label("Full Disk Access needed", systemImage: "lock.shield")
                .foregroundStyle(.orange).font(.caption)
                .labelStyle(.titleAndIcon)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
    }
}

// MARK: - Staged

struct StagedView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.syncService) private var syncService

    var body: some View {
        VStack(spacing: 0) {
            if state.stagedMessages.isEmpty {
                EmptyStagedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MessagesTableView(messages: state.stagedMessages)
            }
            Divider()
            ActionBarView(
                onLoad: { Task { await syncService?.loadStaged() } },
                onSync: { Task { await syncService?.runSync() } }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

struct EmptyStagedView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            if case .noPermission = state.status {
                Image(systemName: "lock.shield")
                    .font(.system(size: 42))
                    .foregroundStyle(.orange)
                Text("Full Disk Access required")
                    .font(.title3.weight(.semibold))
                Text("odit-bridge needs to read ~/Library/Messages/chat.db.\nGrant Full Disk Access in System Settings, then click Load now.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 42))
                    .foregroundStyle(.tertiary)
                Text("Nothing staged yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Click Load now to scan chat.db, then review before syncing.")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(32)
    }
}

struct PlaceholderView: View {
    let title: String
    let systemImage: String
    let caption: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(caption)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Messages table (staged)

struct MessagesTableView: View {
    let messages: [SmsExport]

    var body: some View {
        Table(messages) {
            TableColumn("Sender", value: \.address)
                .width(min: 90, ideal: 130, max: 180)
            TableColumn("Date") { msg in
                Text(formatDate(msg.date))
            }
            .width(min: 140, ideal: 160, max: 200)
            TableColumn("Direction") { msg in
                Text(msg.messageDirection.capitalized)
                    .foregroundStyle(msg.messageDirection == "INCOMING" ? .primary : .secondary)
            }
            .width(min: 90, ideal: 100, max: 120)
            TableColumn("Body") { msg in
                Text(msg.body.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatDate(_ epochMs: String) -> String {
        guard let ms = Int64(epochMs) else { return epochMs }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Action bar (Staged-only)

struct ActionBarView: View {
    let onLoad: () -> Void
    let onSync: () -> Void

    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            if stagedCount == 0 {
                Button(action: onLoad) {
                    Label("Load now", systemImage: "tray.and.arrow.down")
                }
                .keyboardShortcut("l", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)

                Button(action: onSync) {
                    Label("Sync now", systemImage: "arrow.up.circle")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(true)
            } else {
                Button(action: onLoad) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(isBusy)

                Button(action: onSync) {
                    Label("Sync now", systemImage: "arrow.up.circle")
                }
                .keyboardShortcut("r", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }

            Spacer()
            if stagedCount > 0 {
                Text("\(stagedCount) staged for sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state.totalSyncedThisSession > 0 {
                Text("\(state.totalSyncedThisSession) synced this session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stagedCount: Int { state.stagedMessages.count }

    private var isBusy: Bool {
        switch state.status {
        case .loading, .syncing: return true
        default: return false
        }
    }
}

// MARK: - Synced view (unchanged from previous)

struct SyncedView: View {
    @EnvironmentObject var state: AppState
    let onRefresh: () -> Void

    @State private var selectedTransactionId: SyncedTransaction.ID?
    @State private var inspecting: SyncedTransaction?

    private var visibleTransactions: [SyncedTransaction] {
        guard let day = state.appliedDayFilter else { return state.syncedTransactions }
        let calendar = Calendar.current
        return state.syncedTransactions.filter { tx in
            guard let date = SyncedView.parseRawDate(tx.rawDate) else { return false }
            return calendar.isDate(date, inSameDayAs: day)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if state.syncedLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching from server…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let err = state.syncedError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if state.syncedTransactions.isEmpty {
                    Text("No synced transactions yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(visibleTransactions.count) of \(state.syncedTransactions.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let day = state.appliedDayFilter {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption)
                        Text(day.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                        Button {
                            state.appliedDayFilter = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear day filter")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Spacer()
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state.syncedLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            Divider()
            if state.syncedTransactions.isEmpty && !state.syncedLoading {
                VStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Nothing to show yet")
                        .foregroundStyle(.secondary)
                    Text("Sync some messages and the server-parsed transactions will appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                SyncedTable(
                    transactions: visibleTransactions,
                    selection: $selectedTransactionId
                )
            }
        }
        .onChange(of: selectedTransactionId) { _, newId in
            guard let id = newId else { return }
            inspecting = state.syncedTransactions.first(where: { $0.id == id })
        }
        .sheet(item: $inspecting, onDismiss: { selectedTransactionId = nil }) { tx in
            TransactionDetailSheet(transaction: tx)
        }
    }

    static func parseRawDate(_ raw: String) -> Date? {
        if let ms = Int64(raw) {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}

struct SyncedTable: View {
    let transactions: [SyncedTransaction]
    @Binding var selection: SyncedTransaction.ID?

    var body: some View {
        Table(transactions, selection: $selection) {
            TableColumn("") { tx in
                Image(systemName: tx.rawMessageDirection == "OUTGOING" ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(tx.rawMessageDirection == "OUTGOING" ? .red : .green)
            }
            .width(24)

            TableColumn("Date") { tx in
                Text(formatDate(tx.rawDate))
                    .font(.callout)
            }
            .width(min: 110, ideal: 140, max: 170)

            TableColumn("Type") { tx in
                if let type = tx.messageType {
                    Text(type.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.callout)
                } else if tx.isExtracted {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    Text("pending").font(.caption).foregroundStyle(.orange)
                }
            }
            .width(min: 90, ideal: 110, max: 140)

            TableColumn("Provider") { tx in
                Text(tx.rawAddress)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 95, max: 130)

            TableColumn("Counterparty") { tx in
                Text(tx.primaryParticipant?.displayName ?? "—")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 110, ideal: 170)

            TableColumn("Amount") { tx in
                Text(tx.amountText ?? "—")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(tx.rawMessageDirection == "OUTGOING" ? .red : .green)
            }
            .width(min: 90, ideal: 120, max: 160)

            TableColumn("Balance") { tx in
                Text(tx.balanceAfterText ?? "")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110, max: 150)

            TableColumn("Reason") { tx in
                Text(tx.reason ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func formatDate(_ rawDate: String) -> String {
        if let ms = Int64(rawDate) {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                .formatted(date: .abbreviated, time: .shortened)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: rawDate) {
            return d.formatted(date: .abbreviated, time: .shortened)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: rawDate) {
            return d.formatted(date: .abbreviated, time: .shortened)
        }
        return rawDate
    }
}
