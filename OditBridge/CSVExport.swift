import AppKit
import Foundation
import UniformTypeIdentifiers

// CSV export for the synced transactions list. Columns chosen for the most
// common spreadsheet/analytics workflow: sortable ISO timestamp first, raw
// body last so it doesn't clutter the early columns but is available for
// audit.
enum CSVExport {

    static let columns: [String] = [
        "Date",
        "Direction",
        "Type",
        "Provider",
        "Counterparty",
        "Amount",
        "Currency",
        "Fee",
        "BalanceAfter",
        "Category",
        "Reason",
        "InternalTransfer",
        "MessageID",
        "RawBody"
    ]

    static func build(transactions: [SyncedTransaction], categories: [Category]) -> String {
        let catLookup = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        var lines: [String] = [columns.joined(separator: ",")]
        for tx in transactions {
            let row: [String] = [
                isoDate(tx.rawDate),
                tx.rawMessageDirection ?? "",
                tx.messageType ?? "",
                tx.rawAddress,
                tx.primaryParticipant?.displayName ?? "",
                tx.principalAmount ?? "",
                tx.principalCurrency ?? "",
                tx.feeAmount ?? "",
                tx.balanceAfterAmount ?? "",
                tx.categoryId.flatMap { catLookup[$0] } ?? "",
                tx.reason ?? "",
                (tx.isInternalTransfer ?? false) ? "YES" : "NO",
                tx.rawId,
                tx.rawBody
            ]
            lines.append(row.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Returns the URL the user picked, or nil if they cancelled.
    @MainActor
    static func showSavePanel(suggestedFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.title = "Export synced transactions"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func suggestedFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "odit-transactions-\(f.string(from: Date())).csv"
    }

    // MARK: helpers

    private static func escape(_ field: String) -> String {
        // RFC 4180: quote if the field contains commas, quotes, or newlines.
        // Double any embedded quotes.
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }

    private static func isoDate(_ raw: String) -> String {
        // rawDate is either epoch-ms-as-string (server-side from chat.db) or
        // an ISO timestamp. Normalise to ISO for spreadsheet sortability.
        if let ms = Int64(raw) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            return iso.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        }
        return raw
    }
}
