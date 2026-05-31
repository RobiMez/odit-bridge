import Foundation
import SwiftUI

enum DefaultsKey {
    static let clientId = "odit.clientId"
    static let apiBaseURL = "odit.apiBaseURL"
    static let lastSyncedRowId = "odit.lastSyncedRowId"
    static let lastSyncDate = "odit.lastSyncDate"
    static let linkBannerDismissed = "odit.linkBannerDismissed"
}

final class Settings: ObservableObject {
    private let defaults: UserDefaults

    @Published private(set) var clientId: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let existing = DeviceIdentity.read() {
            self.clientId = existing
        } else {
            let fresh = UUID().uuidString.lowercased()
            DeviceIdentity.write(fresh)
            self.clientId = fresh
        }
        if defaults.string(forKey: DefaultsKey.apiBaseURL) == nil {
            defaults.set("http://localhost:3000", forKey: DefaultsKey.apiBaseURL)
        }
    }

    // Replace the device's clientId. Used when a user wants to recover an
    // earlier UUID (e.g. they copied it from the web app after the local one
    // got regenerated). Returns false if the input isn't a valid UUID.
    @discardableResult
    func setClientId(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: trimmed) != nil else { return false }
        DeviceIdentity.write(trimmed)
        clientId = trimmed
        // Changing identity invalidates any cursor we had on the old device.
        resetCursor()
        return true
    }

    var apiBaseURL: String {
        get { defaults.string(forKey: DefaultsKey.apiBaseURL) ?? "" }
        set {
            defaults.set(newValue, forKey: DefaultsKey.apiBaseURL)
            objectWillChange.send()
        }
    }

    var lastSyncedRowId: Int64 {
        get { Int64(defaults.integer(forKey: DefaultsKey.lastSyncedRowId)) }
        set {
            defaults.set(Int(newValue), forKey: DefaultsKey.lastSyncedRowId)
            objectWillChange.send()
        }
    }

    var lastSyncDate: Date? {
        get { defaults.object(forKey: DefaultsKey.lastSyncDate) as? Date }
        set {
            defaults.set(newValue, forKey: DefaultsKey.lastSyncDate)
            objectWillChange.send()
        }
    }

    var linkBannerDismissed: Bool {
        get { defaults.bool(forKey: DefaultsKey.linkBannerDismissed) }
        set {
            defaults.set(newValue, forKey: DefaultsKey.linkBannerDismissed)
            objectWillChange.send()
        }
    }

    func resetCursor() {
        defaults.removeObject(forKey: DefaultsKey.lastSyncedRowId)
        objectWillChange.send()
    }
}

enum ConnectionStatus: Equatable {
    case idle
    case loading
    case syncing(uploaded: Int, total: Int)
    case ok
    case noPermission
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: ConnectionStatus = .idle
    @Published var stagedMessages: [SmsExport] = []
    @Published var syncedTransactions: [SyncedTransaction] = []
    @Published var syncedLoading: Bool = false
    @Published var syncedError: String?
    @Published var logs: [SyncLogEntry] = []
    @Published var totalSyncedThisSession: Int = 0
    /// If non-nil, the Synced view filters its table to transactions whose
    /// rawDate falls on this calendar day. Set by the heatmap when a cell is
    /// clicked. Cleared by the Synced view's "Clear filter" affordance.
    @Published var appliedDayFilter: Date?

    private let maxLogs = 500

    func log(_ message: String, level: SyncLogEntry.Level = .info) {
        let entry = SyncLogEntry(timestamp: Date(), level: level, message: message)
        logs.insert(entry, at: 0)
        if logs.count > maxLogs {
            logs.removeLast(logs.count - maxLogs)
        }
    }
}

// Slow-moving reference data fetched from the server. Kept separate from
// AppState so a refresh of syncedTransactions doesn't invalidate downstream
// category-color / provider-color lookups in chart legends, etc.
@MainActor
final class ReferenceData: ObservableObject {
    @Published var categories: [Category] = []
    @Published var providers: [Provider] = []
    @Published var chartsSummary: ChartsSummary?

    @Published var categoriesLoading: Bool = false
    @Published var providersLoading: Bool = false
    @Published var summaryLoading: Bool = false
    @Published var lastError: String?

    func category(forId id: Int?) -> Category? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    func provider(forKey key: String) -> Provider? {
        providers.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }
}
