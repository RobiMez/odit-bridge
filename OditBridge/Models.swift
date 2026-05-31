import Foundation

struct SmsExport: Codable, Identifiable, Hashable {
    let id: String
    let threadId: String
    let address: String
    let contactName: String
    let body: String
    let date: String
    let type: String
    let messageType: String
    let messageDirection: String
    let read: String
    let seen: String
    let status: String
    let errorCode: String
    let serviceCenter: String?
    let replyPathPresent: String
    let locked: String
    let `protocol`: String
}

struct SmsExportBatch: Codable {
    let clientId: String
    let messages: [SmsExport]
}

struct SyncResponse: Codable {
    let status: String
    let received: Int
    let newMessages: Int
    let duplicates: Int
    let patternVersion: String?
}

struct ChatDbRow {
    let rowId: Int64
    let guid: String?
    let handleAddress: String
    let body: String
    let dateNanos: Int64
    let isFromMe: Bool
    let service: String?
    let handleId: Int64
    let read: Bool

    var epochMs: Int64 {
        // chat.db date is nanoseconds since 2001-01-01 UTC (Mac reference date)
        let appleEpochOffsetMs: Int64 = 978_307_200_000
        return dateNanos / 1_000_000 + appleEpochOffsetMs
    }

    func toSmsExport() -> SmsExport {
        SmsExport(
            id: String(rowId),
            threadId: String(handleId),
            address: handleAddress,
            contactName: handleAddress,
            body: body,
            date: String(epochMs),
            type: isFromMe ? "2" : "1",
            messageType: "SMS",
            messageDirection: isFromMe ? "OUTGOING" : "INCOMING",
            read: read ? "1" : "0",
            seen: read ? "1" : "0",
            status: "-1",
            errorCode: "0",
            serviceCenter: nil,
            replyPathPresent: "0",
            locked: "0",
            protocol: "0"
        )
    }
}

// Excludes addresses we don't want to upload. Generalised port of
// odit_sync/.../data/model/SmsFilter.kt — same intent (no personal contacts in
// the upload) but country-agnostic.
//
// Strategy after stripping " -().":
//   - Contains any non-digit (besides a single leading `+`) → alpha sender like
//     "CBE" or "safaricom" → KEEP.
//   - Digit count ≥ 7 → personal phone number (E.164 with country code, local
//     format, or a concatenated recipient blob from group MMS) → DROP.
//   - Digit count ≤ 6 → short code like "127", "889", "251994" → KEEP.
enum SmsFilter {
    private static let minPhoneDigitCount = 7
    private static let separators = CharacterSet(charactersIn: " -().")

    static func isExcluded(address: String?) -> Bool {
        guard let raw = address?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return false }
        let compact = raw.components(separatedBy: separators).joined()
        if compact.isEmpty { return false }

        let digits = compact.hasPrefix("+") ? compact.dropFirst() : Substring(compact)
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return false }
        return digits.count >= minPhoneDigitCount
    }
}

// MARK: - Synced / extracted transactions

// Mirrors `MessageData` from odit_sync/.../data/dto/MessageData.kt — the row
// shape returned by GET /api/v2/messages/:deviceId after server-side extraction.
struct SyncedTransaction: Codable, Identifiable, Hashable {
    let id: Int
    let deviceId: Int
    let rawId: String
    let rawAddress: String
    let rawContactName: String?
    let rawBody: String
    let rawDate: String
    let rawMessageDirection: String?

    let messageType: String?
    let principalAmount: String?
    let principalCurrency: String?
    let feeAmount: String?
    let feeCurrency: String?
    let balanceBeforeAmount: String?
    let balanceBeforeCurrency: String?
    let balanceAfterAmount: String?
    let balanceAfterCurrency: String?

    let extractedAt: String?
    let providerId: Int?
    // Mutable to support in-place edits after a successful PATCH (set category)
    // or mark-internal POST. The Codable conformance treats them the same as
    // `let` — only writability changes.
    var categoryId: Int?
    var reason: String?

    var isInternalTransfer: Bool?
    let extractionParticipants: [ExtractionParticipant]?

    var isExtracted: Bool { extractedAt != nil }

    var directionLabel: String {
        rawMessageDirection?.capitalized ?? "—"
    }

    var primaryParticipant: ExtractionParticipant? {
        // For outgoing show the receiver, for incoming show the sender.
        let prefer: String = (rawMessageDirection == "OUTGOING") ? "RECEIVER" : "SENDER"
        return extractionParticipants?.first(where: { $0.role == prefer })
            ?? extractionParticipants?.first
    }

    var amountText: String? {
        guard let amount = principalAmount else { return nil }
        let sign = (rawMessageDirection == "OUTGOING") ? "−" : "+"
        let currency = principalCurrency ?? ""
        return "\(sign)\(amount) \(currency)".trimmingCharacters(in: .whitespaces)
    }

    var balanceAfterText: String? {
        guard let bal = balanceAfterAmount else { return nil }
        let currency = balanceAfterCurrency ?? ""
        return "Bal \(bal) \(currency)".trimmingCharacters(in: .whitespaces)
    }
}

struct ExtractionParticipant: Codable, Hashable {
    let id: Int
    let messageId: Int
    let accountIdentifier: String
    let accountName: String?
    let accountType: String
    let role: String        // "SENDER" | "RECEIVER" | "MERCHANT"
    let type: String        // "PARTICIPANT" | "WALLET" | "INTERNAL"
    let participantId: Int?
    let walletId: Int?

    var displayName: String {
        accountName ?? accountIdentifier
    }
}

struct MessagesPagination: Codable, Hashable {
    let total: Int
    let limit: Int
    let skip: Int
    let hasMore: Bool
}

struct MessagesListResponse: Codable {
    let success: Bool
    let data: [SyncedTransaction]?
    let pagination: MessagesPagination?
    let error: String?
}

struct SingleTransactionResponse: Codable {
    let success: Bool
    let data: SyncedTransaction?
    let error: String?
}

// MARK: - Categories / providers (reference data)

struct Category: Codable, Identifiable, Hashable {
    let id: Int
    let userId: String?
    let name: String
    let color: String
    let isDefault: Bool?
}

struct CategoriesResponse: Codable {
    let success: Bool
    let data: [Category]?
    let error: String?
}

struct Provider: Codable, Identifiable, Hashable {
    let id: Int
    let key: String
    let name: String
    let colors: ProviderColors?
}

struct ProviderColors: Codable, Hashable {
    let light: ProviderFgBg
    let dark: ProviderFgBg
}

struct ProviderFgBg: Codable, Hashable {
    let fg: String
    let bg: String
}

struct ProvidersResponse: Codable {
    let status: String?
    let providers: [Provider]
    let count: Int?
}

// MARK: - Charts summary

struct ChartsSummaryResponse: Codable {
    let success: Bool
    let data: ChartsSummary?
    let error: String?
}

struct ChartsSummary: Codable {
    let periods: [String: ChartsPeriod]
    let balances: [String: Double]?
}

struct ChartsPeriod: Codable {
    let byProvider: [String: ChartsProviderFlow]
    let combined: ChartsCombined
    let period: ChartsPeriodBounds
}

struct ChartsProviderFlow: Codable, Hashable {
    let totalIncoming: Double
    let totalOutgoing: Double
    let totalFees: Double
    let net: Double
    let transactionCount: Int
}

struct ChartsCombined: Codable, Hashable {
    let totalIncoming: Double
    let totalOutgoing: Double
    let totalFees: Double
    let net: Double
    let totalTransactions: Int
    let currentBalance: Double?
}

struct ChartsPeriodBounds: Codable, Hashable {
    let type: String
    let startDate: String
    let endDate: String
}

struct SyncLogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level: String, Codable {
        case info
        case warn
        case error
    }
}
