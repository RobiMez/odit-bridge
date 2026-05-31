import Foundation
import SQLite3

enum ChatDBError: LocalizedError {
    case permissionDenied
    case notFound
    case openFailed(String)
    case sql(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Full Disk Access is required to read ~/Library/Messages/chat.db."
        case .notFound:
            return "chat.db not found. iMessage / SMS forwarding must be set up on this Mac."
        case .openFailed(let msg):
            return "Could not open chat.db: \(msg)"
        case .sql(let msg):
            return "Database error: \(msg)"
        }
    }
}

final class ChatDB {
    static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Messages/chat.db"
    }

    private let dbPath: String

    init(path: String = ChatDB.defaultPath) {
        self.dbPath = path
    }

    func isReadable() -> Bool {
        FileManager.default.isReadableFile(atPath: dbPath)
    }

    func exists() -> Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    struct StagedSnapshot {
        let count: Int
        let maxRowId: Int64
    }

    func snapshotStaged(since lastRowId: Int64) throws -> StagedSnapshot {
        guard exists() else { throw ChatDBError.notFound }
        guard isReadable() else { throw ChatDBError.permissionDenied }

        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro&immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let openResult = sqlite3_open_v2(uri, &db, flags, nil)
        defer { if db != nil { sqlite3_close(db) } }

        guard openResult == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open error \(openResult)"
            if openResult == SQLITE_CANTOPEN || openResult == SQLITE_PERM || openResult == SQLITE_AUTH {
                throw ChatDBError.permissionDenied
            }
            throw ChatDBError.openFailed(msg)
        }

        let sql = """
            SELECT m.ROWID, h.id
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > ?
              AND m.text IS NOT NULL
              AND m.service = 'SMS';
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ChatDBError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastRowId)

        var count = 0
        var maxRowId: Int64 = lastRowId
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            if rowId > maxRowId { maxRowId = rowId }
            guard let addrC = sqlite3_column_text(stmt, 1) else { continue }
            let addr = String(cString: addrC)
            if !SmsFilter.isExcluded(address: addr) {
                count += 1
            }
        }
        return StagedSnapshot(count: count, maxRowId: maxRowId)
    }

    func read(since lastRowId: Int64, upTo maxRowId: Int64 = .max, limit: Int = 1000) throws -> [ChatDbRow] {
        guard exists() else { throw ChatDBError.notFound }
        guard isReadable() else { throw ChatDBError.permissionDenied }

        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro&immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let openResult = sqlite3_open_v2(uri, &db, flags, nil)
        defer { if db != nil { sqlite3_close(db) } }

        guard openResult == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open error \(openResult)"
            if openResult == SQLITE_CANTOPEN || openResult == SQLITE_PERM || openResult == SQLITE_AUTH {
                throw ChatDBError.permissionDenied
            }
            throw ChatDBError.openFailed(msg)
        }

        let sql = """
            SELECT
                m.ROWID,
                m.guid,
                h.ROWID,
                h.id,
                m.text,
                m.date,
                m.is_from_me,
                m.service,
                m.is_read
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > ?
              AND m.ROWID <= ?
              AND m.text IS NOT NULL
              AND m.service = 'SMS'
            ORDER BY m.ROWID ASC
            LIMIT ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ChatDBError.sql(msg)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, lastRowId)
        sqlite3_bind_int64(stmt, 2, maxRowId)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var rows: [ChatDbRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let guid = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let handleId = sqlite3_column_int64(stmt, 2)
            guard let addressC = sqlite3_column_text(stmt, 3),
                  let bodyC = sqlite3_column_text(stmt, 4)
            else { continue }
            let address = String(cString: addressC)
            let body = String(cString: bodyC).replacingOccurrences(of: "\0", with: "")
            let dateNanos = sqlite3_column_int64(stmt, 5)
            let isFromMe = sqlite3_column_int(stmt, 6) == 1
            let service = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let read = sqlite3_column_int(stmt, 8) == 1

            rows.append(ChatDbRow(
                rowId: rowId,
                guid: guid,
                handleAddress: address,
                body: body,
                dateNanos: dateNanos,
                isFromMe: isFromMe,
                service: service,
                handleId: handleId,
                read: read
            ))
        }
        return rows
    }
}
