import SwiftUI

@main
struct OditBridgeApp: App {
    @StateObject private var settings = Settings()
    @StateObject private var state = AppState()
    @StateObject private var reference = ReferenceData()
    @State private var syncService: SyncService?

    var body: some Scene {
        WindowGroup("odit-bridge") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(state)
                .environmentObject(reference)
                .environment(\.syncService, syncService)
                .task { await bootstrap() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Load now") {
                    Task { await syncService?.loadStaged() }
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("Sync now") {
                    Task { await syncService?.runSync() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Getting Started") {
                    NotificationCenter.default.post(
                        name: .oditShowGettingStarted, object: nil
                    )
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }

    @MainActor
    private func bootstrap() async {
        if syncService == nil {
            syncService = SyncService(settings: settings, state: state, reference: reference)
            state.log("odit-bridge started.")
        }
        // Auto-pull what we already have on the server so the user sees fresh
        // data immediately. This is read-only — no SMS get uploaded without
        // explicit Load + Sync.
        guard let svc = syncService else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await svc.fetchSynced() }
            group.addTask { await svc.fetchProviders() }
            group.addTask { await svc.fetchCategories() }
            group.addTask { await svc.fetchSummary() }
        }
    }
}

extension Notification.Name {
    /// Fired from the Help menu so any visible window can present the
    /// Getting Started sheet.
    static let oditShowGettingStarted = Notification.Name("oditShowGettingStarted")
}

private struct SyncServiceKey: EnvironmentKey {
    static let defaultValue: SyncService? = nil
}

extension EnvironmentValues {
    var syncService: SyncService? {
        get { self[SyncServiceKey.self] }
        set { self[SyncServiceKey.self] = newValue }
    }
}
