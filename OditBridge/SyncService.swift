import Foundation

enum SyncError: LocalizedError {
    case invalidBaseURL
    case httpStatus(Int, String)
    case decode(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "API base URL is invalid."
        case .httpStatus(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .decode(let msg): return "Decode error: \(msg)"
        case .transport(let msg): return "Network error: \(msg)"
        }
    }
}

@MainActor
final class SyncService {
    private let settings: Settings
    private let state: AppState
    private let reference: ReferenceData
    private let session: URLSession

    private let chunkSize = 50
    private let maxRetries = 3

    init(settings: Settings, state: AppState, reference: ReferenceData) {
        self.settings = settings
        self.state = state
        self.reference = reference
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Minutes-from-UTC for the user's current timezone, sent as `?tz=` on
    /// `/charts` requests so period boundaries match local-time expectations.
    private var tzOffsetMinutes: Int { TimeZone.current.secondsFromGMT() / 60 }

    private let readPageSize = 1000

    // Snapshot of chat.db rowids covered by the most recent loadStaged() call.
    // Used by runSync() to advance the cursor past everything that was staged —
    // including rows that the filter dropped — once the upload completes.
    private var stagedMaxRowId: Int64 = 0
    private var stagedRawTotal: Int = 0

    func loadStaged() async {
        do {
            try await performLoad()
        } catch {
            state.status = .error(error.localizedDescription)
            state.log("Load failed: \(error.localizedDescription)", level: .error)
        }
    }

    func runSync() async {
        do {
            try await performSync()
        } catch {
            state.status = .error(error.localizedDescription)
            state.log("Sync failed: \(error.localizedDescription)", level: .error)
        }
    }

    func fetchSynced(pageSize: Int = 500) async {
        let baseURL = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, let root = URL(string: baseURL) else {
            state.syncedError = "API base URL is invalid."
            return
        }
        state.syncedLoading = true
        state.syncedError = nil
        defer { state.syncedLoading = false }

        let clientId = settings.clientId
        let base = root.appendingPathComponent("api/v2/messages").appendingPathComponent(clientId)
        var skip = 0
        // Build into a local var and assign once at the end so anything binding
        // to `state.syncedTransactions` (charts, heatmap) doesn't flash through
        // an empty state on refresh.
        var collected: [SyncedTransaction] = []

        while true {
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "skip", value: String(skip)),
                URLQueryItem(name: "sortBy", value: "rawDate"),
                URLQueryItem(name: "sortOrder", value: "desc")
            ]
            guard let url = components?.url else {
                state.syncedError = "Could not build messages URL."
                return
            }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(clientId, forHTTPHeaderField: "x-odit-device-id")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    state.syncedError = "Non-HTTP response"
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    state.syncedError = "HTTP \(http.statusCode): \(body.prefix(200))"
                    return
                }
                let decoded = try JSONDecoder().decode(MessagesListResponse.self, from: data)
                if decoded.success == false, let err = decoded.error {
                    state.syncedError = err
                    return
                }
                let page = decoded.data ?? []
                collected.append(contentsOf: page)
                let hasMore = decoded.pagination?.hasMore ?? (page.count >= pageSize)
                if !hasMore || page.isEmpty { break }
                skip += page.count
            } catch {
                state.syncedError = error.localizedDescription
                state.log("Fetch synced failed: \(error.localizedDescription)", level: .warn)
                return
            }
        }

        state.syncedTransactions = collected
        state.log("Fetched \(collected.count) synced transaction(s).")
    }

    // MARK: - Reference data fetches

    func fetchCategories() async {
        guard let url = referenceURL("api/v2/categories/me") else {
            reference.lastError = "Invalid API base URL."
            return
        }
        reference.categoriesLoading = true
        defer { reference.categoriesLoading = false }
        do {
            let data = try await getJSON(url)
            let decoded = try JSONDecoder().decode(CategoriesResponse.self, from: data)
            reference.categories = decoded.data ?? []
        } catch {
            reference.lastError = "Categories fetch: \(error.localizedDescription)"
            state.log("Categories fetch failed: \(error.localizedDescription)", level: .warn)
        }
    }

    func fetchProviders() async {
        guard let url = referenceURL("api/v2/providers") else {
            reference.lastError = "Invalid API base URL."
            return
        }
        reference.providersLoading = true
        defer { reference.providersLoading = false }
        do {
            let data = try await getJSON(url)
            let decoded = try JSONDecoder().decode(ProvidersResponse.self, from: data)
            reference.providers = decoded.providers
        } catch {
            reference.lastError = "Providers fetch: \(error.localizedDescription)"
            state.log("Providers fetch failed: \(error.localizedDescription)", level: .warn)
        }
    }

    func fetchSummary() async {
        let path = "api/v2/charts/\(settings.clientId)/summary-all"
        guard var components = referenceComponents(path) else {
            reference.lastError = "Invalid API base URL."
            return
        }
        components.queryItems = [URLQueryItem(name: "tz", value: String(tzOffsetMinutes))]
        guard let url = components.url else { return }
        reference.summaryLoading = true
        defer { reference.summaryLoading = false }
        do {
            let data = try await getJSON(url)
            let decoded = try JSONDecoder().decode(ChartsSummaryResponse.self, from: data)
            reference.chartsSummary = decoded.data
        } catch {
            reference.lastError = "Summary fetch: \(error.localizedDescription)"
            state.log("Summary fetch failed: \(error.localizedDescription)", level: .warn)
        }
    }

    // MARK: - Reference helpers

    private func referenceURL(_ path: String) -> URL? {
        referenceComponents(path)?.url
    }

    private func referenceComponents(_ path: String) -> URLComponents? {
        let baseURL = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, let root = URL(string: baseURL) else { return nil }
        let full = root.appendingPathComponent(path)
        return URLComponents(url: full, resolvingAgainstBaseURL: false)
    }

    // MARK: - Per-transaction enrichment

    /// PATCH /messages/:deviceId/:id with the changed fields. `categoryId == nil`
    /// clears any existing category override. Returns the server's updated
    /// representation, also updated in `state.syncedTransactions` in place.
    @discardableResult
    func updateTransaction(id: Int, categoryId: Int?, reason: String?) async throws -> SyncedTransaction {
        let path = "api/v2/messages/\(settings.clientId)/\(id)"
        guard let url = referenceURL(path) else {
            throw SyncError.invalidBaseURL
        }
        var body: [String: Any] = [:]
        // Explicit NSNull → JSON null so server clears the override.
        body["categoryId"] = categoryId as Any? ?? NSNull()
        body["reason"] = reason as Any? ?? NSNull()
        let payload = try JSONSerialization.data(withJSONObject: body)

        let data = try await sendJSON(url, method: "PATCH", body: payload)
        let decoded = try JSONDecoder().decode(SingleTransactionResponse.self, from: data)
        guard let updated = decoded.data else {
            throw SyncError.decode("Missing 'data' in PATCH response")
        }
        replaceInState(updated)
        state.log("Updated message #\(id).")
        return updated
    }

    /// POST /messages/:deviceId/:id/mark-internal. Body `{ isInternal }`. The
    /// server replies with a status envelope (no full message), so we flip the
    /// flag in place locally.
    func markInternal(id: Int, isInternal: Bool) async throws {
        let path = "api/v2/messages/\(settings.clientId)/\(id)/mark-internal"
        guard let url = referenceURL(path) else {
            throw SyncError.invalidBaseURL
        }
        let payload = try JSONSerialization.data(withJSONObject: ["isInternal": isInternal])
        _ = try await sendJSON(url, method: "POST", body: payload)

        if let idx = state.syncedTransactions.firstIndex(where: { $0.id == id }) {
            state.syncedTransactions[idx].isInternalTransfer = isInternal
        }
        state.log("Marked message #\(id) as \(isInternal ? "internal" : "not internal").")
    }

    private func replaceInState(_ tx: SyncedTransaction) {
        if let idx = state.syncedTransactions.firstIndex(where: { $0.id == tx.id }) {
            state.syncedTransactions[idx] = tx
        }
    }

    private func sendJSON(_ url: URL, method: String, body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(settings.clientId, forHTTPHeaderField: "x-odit-device-id")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.httpStatus(http.statusCode, bodyText)
        }
        return data
    }

    private func getJSON(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(settings.clientId, forHTTPHeaderField: "x-odit-device-id")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.httpStatus(http.statusCode, body)
        }
        return data
    }

    private func performLoad() async throws {
        let db = ChatDB()
        state.status = .loading
        state.log("Scanning chat.db since rowid \(settings.lastSyncedRowId)…")

        let snapshot: ChatDB.StagedSnapshot
        do {
            snapshot = try db.snapshotStaged(since: settings.lastSyncedRowId)
        } catch ChatDBError.permissionDenied {
            state.status = .noPermission
            state.log("Permission denied — grant Full Disk Access.", level: .error)
            return
        }

        guard snapshot.count > 0 else {
            state.stagedMessages = []
            stagedMaxRowId = 0
            stagedRawTotal = 0
            state.status = .ok
            state.log("No new messages.")
            return
        }

        let cap = snapshot.maxRowId
        var staged: [SmsExport] = []
        staged.reserveCapacity(snapshot.count)
        var cursor = settings.lastSyncedRowId
        var rawScanned = 0

        while cursor < cap {
            let rows: [ChatDbRow]
            do {
                rows = try db.read(since: cursor, upTo: cap, limit: readPageSize)
            } catch ChatDBError.permissionDenied {
                state.status = .noPermission
                state.log("Permission denied — grant Full Disk Access.", level: .error)
                return
            }
            if rows.isEmpty { break }

            rawScanned += rows.count
            let kept = rows.filter { !SmsFilter.isExcluded(address: $0.handleAddress) }
            staged.append(contentsOf: kept.map { $0.toSmsExport() })

            if let maxRow = rows.map(\.rowId).max() {
                cursor = maxRow
            } else {
                break
            }
            if rows.count < readPageSize { break }
        }

        state.stagedMessages = staged
        stagedMaxRowId = cap
        stagedRawTotal = rawScanned
        state.status = .ok
        let filtered = rawScanned - staged.count
        if filtered > 0 {
            state.log("Loaded \(staged.count) message(s) for review (\(filtered) filtered). Click Sync now to upload.")
        } else {
            state.log("Loaded \(staged.count) message(s) for review. Click Sync now to upload.")
        }
    }

    private func performSync() async throws {
        let baseURL = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, URL(string: baseURL) != nil else {
            throw SyncError.invalidBaseURL
        }

        let staged = state.stagedMessages
        guard !staged.isEmpty else {
            state.log("Nothing to sync — click Load now first.", level: .warn)
            return
        }

        let total = staged.count
        state.status = .syncing(uploaded: 0, total: total)
        state.log("Uploading \(total) staged message(s)…")

        var uploaded = 0
        for chunk in staged.chunks(ofCount: chunkSize) {
            let chunkArray = Array(chunk)
            try await uploadChunk(chunk: chunkArray, baseURL: baseURL)
            uploaded += chunkArray.count
            state.status = .syncing(uploaded: uploaded, total: total)
            let uploadedIds = Set(chunkArray.map { $0.id })
            state.stagedMessages.removeAll { uploadedIds.contains($0.id) }
            state.totalSyncedThisSession += chunkArray.count
        }

        // Cursor advances past every rowid covered by the load — including those
        // SmsFilter dropped — so the next Load doesn't re-scan them.
        if stagedMaxRowId > settings.lastSyncedRowId {
            settings.lastSyncedRowId = stagedMaxRowId
        }
        stagedMaxRowId = 0
        stagedRawTotal = 0

        try await finalize(baseURL: baseURL)

        state.status = .ok
        settings.lastSyncDate = Date()
        state.log("Sync complete — synced \(uploaded) message(s). Fetching parsed transactions…")
        await fetchSynced()
    }

    private func uploadChunk(chunk: [SmsExport], baseURL: String) async throws {
        let batch = SmsExportBatch(clientId: settings.clientId, messages: chunk)
        let body = try JSONEncoder().encode(batch)
        let url = URL(string: baseURL)!.appendingPathComponent("api/v2/sync/sms")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SyncError.transport("Non-HTTP response")
                }
                if (200..<300).contains(http.statusCode) {
                    if let resp = try? JSONDecoder().decode(SyncResponse.self, from: data) {
                        state.log("  chunk: received=\(resp.received) new=\(resp.newMessages) dup=\(resp.duplicates)")
                    }
                    return
                }
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                if http.statusCode >= 500, attempt <= maxRetries {
                    let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                    state.log("HTTP \(http.statusCode) — retrying in \(attempt * 2)s", level: .warn)
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
                throw SyncError.httpStatus(http.statusCode, bodyText)
            } catch let e as SyncError {
                throw e
            } catch {
                if attempt <= maxRetries {
                    let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                    state.log("Network error — retrying in \(attempt * 2)s", level: .warn)
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
                throw SyncError.transport(error.localizedDescription)
            }
        }
    }

    private func finalize(baseURL: String) async throws {
        let url = URL(string: baseURL)!.appendingPathComponent("api/v2/sync/finalize")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["clientId": settings.clientId])

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                state.log("Finalize returned non-2xx — skipping", level: .warn)
                return
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload.isEmpty || payload == "{}" { continue }
                state.log("  finalize: \(payload)")
            }
        } catch {
            state.log("Finalize error: \(error.localizedDescription)", level: .warn)
        }
    }
}

private extension Array {
    func chunks(ofCount n: Int) -> [ArraySlice<Element>] {
        guard n > 0 else { return [] }
        var result: [ArraySlice<Element>] = []
        var i = 0
        while i < count {
            let end = Swift.min(i + n, count)
            result.append(self[i..<end])
            i = end
        }
        return result
    }
}
