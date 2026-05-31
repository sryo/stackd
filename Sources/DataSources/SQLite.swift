import Foundation
import SQLite3

// Minimal libsqlite3 wrapper. exec / query / close — no ORM, no migrations,
// no result-row caching. JS callers get rows back as [[String: Any]]; FTS4 +
// FTS5 ship in macOS's system libsqlite3 (compile-time enabled since 10.10),
// so they're available without any extension-loading dance.
//
// Sandboxing: paths default to ~/stackd/stacks/<id>/data/ (created on first
// open) so a stack can't quietly siphon another stack's DB. Absolute paths
// are accepted but currently NOT gated — the manifest permission "sqlite" is
// the only check; a "sqlite.path" granular permission is a future iteration
// if abuse becomes a thing.

// SQLITE_TRANSIENT tells SQLite to copy the bytes before returning from bind_*.
// Imported as a raw constant because Swift doesn't bridge the macro.
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

enum SQLite {
    final class Connection {
        let path: String
        let db: OpaquePointer
        init(path: String, db: OpaquePointer) {
            self.path = path
            self.db = db
        }
        deinit { sqlite3_close_v2(db) }
    }

    static func open(stackId: String, path: String, mode: String) -> [String: Any]? {
        let resolved = resolvePath(stackId: stackId, requested: path)
        // mkdir -p the parent so first-open of a fresh stack data dir works.
        let parent = (resolved as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        var flags: Int32 = SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        flags |= (mode == "readonly") ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(resolved, &db, flags, nil)
        guard rc == SQLITE_OK, let db = db else {
            if let d = db { sqlite3_close_v2(d) }
            return nil
        }
        let handle = HandleStore.shared.mint(Connection(path: resolved, db: db))
        return [
            "handle": handle,
            "path":   resolved
        ]
    }

    /// Run one-or-more statements that don't return rows (CREATE TABLE, INSERT
    /// without RETURNING, PRAGMA, etc.). sqlite3_exec walks `;`-separated
    /// statements internally — no need to chop them up here.
    static func exec(handle: Int, sql: String) -> [String: Any] {
        guard let conn = HandleStore.shared.get(handle) else {
            return ["ok": false, "error": "invalid handle"]
        }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(conn.db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err = err { sqlite3_free(err) }
            return ["ok": false, "error": msg]
        }
        return [
            "ok":           true,
            "rowsAffected": Int(sqlite3_changes(conn.db)),
            "lastInsertId": Int(sqlite3_last_insert_rowid(conn.db))
        ]
    }

    /// Prepared SELECT with `?` placeholders. params is a flat array of
    /// JSON-friendly values (Int / Double / String / Bool / null). Returns
    /// { rows: [{col: val, ...}], rowsAffected, lastInsertId } so a single
    /// query() call works for SELECT and for INSERT ... RETURNING.
    static func query(handle: Int, sql: String, params: [Any]) -> [String: Any] {
        guard let conn = HandleStore.shared.get(handle) else {
            return ["ok": false, "error": "invalid handle"]
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(conn.db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(conn.db))
            return ["ok": false, "error": msg]
        }
        defer { sqlite3_finalize(stmt) }

        for (i, raw) in params.enumerated() {
            let idx = Int32(i + 1)
            // NSNull → NULL; primitives → typed bind. Anything else gets
            // stringified to avoid bind_blob shenanigans we don't need yet.
            if raw is NSNull {
                sqlite3_bind_null(stmt, idx)
            } else if let v = raw as? Int {
                sqlite3_bind_int64(stmt, idx, Int64(v))
            } else if let v = raw as? Int64 {
                sqlite3_bind_int64(stmt, idx, v)
            } else if let v = raw as? Double {
                sqlite3_bind_double(stmt, idx, v)
            } else if let v = raw as? Bool {
                sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            } else if let v = raw as? String {
                sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            } else {
                let s = String(describing: raw)
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            }
        }

        var rows: [[String: Any]] = []
        let cols = Int(sqlite3_column_count(stmt))
        var colNames: [String] = []
        colNames.reserveCapacity(cols)
        for c in 0..<cols {
            colNames.append(String(cString: sqlite3_column_name(stmt, Int32(c))))
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for c in 0..<cols {
                let ci = Int32(c)
                switch sqlite3_column_type(stmt, ci) {
                case SQLITE_INTEGER:
                    row[colNames[c]] = Int(sqlite3_column_int64(stmt, ci))
                case SQLITE_FLOAT:
                    row[colNames[c]] = sqlite3_column_double(stmt, ci)
                case SQLITE_TEXT:
                    if let cstr = sqlite3_column_text(stmt, ci) {
                        row[colNames[c]] = String(cString: cstr)
                    } else {
                        row[colNames[c]] = NSNull()
                    }
                case SQLITE_NULL:
                    row[colNames[c]] = NSNull()
                case SQLITE_BLOB:
                    // Blob → base64 string. Real blob-heavy stacks can add a
                    // dedicated path later; FTS / settings use cases don't need it.
                    let n = Int(sqlite3_column_bytes(stmt, ci))
                    if n > 0, let ptr = sqlite3_column_blob(stmt, ci) {
                        let data = Data(bytes: ptr, count: n)
                        row[colNames[c]] = data.base64EncodedString()
                    } else {
                        row[colNames[c]] = ""
                    }
                default:
                    row[colNames[c]] = NSNull()
                }
            }
            rows.append(row)
        }

        return [
            "ok":           true,
            "rows":         rows,
            "rowsAffected": Int(sqlite3_changes(conn.db)),
            "lastInsertId": Int(sqlite3_last_insert_rowid(conn.db))
        ]
    }

    @discardableResult
    static func close(handle: Int) -> Bool {
        return HandleStore.shared.release(handle)
    }

    /// Default landing: ~/stackd/stacks/<id>/data/<requested-name>. Absolute
    /// paths (start with "/") and ~-paths are honored as-is — useful for
    /// shared-DB consumers, with the trade-off noted in the file header.
    /// In-memory DBs (":memory:") pass through.
    private static func resolvePath(stackId: String, requested: String) -> String {
        if requested == ":memory:" { return ":memory:" }
        if requested.hasPrefix("/") { return requested }
        if requested.hasPrefix("~") { return (requested as NSString).expandingTildeInPath }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return "\(home)/stackd/stacks/\(stackId)/data/\(requested)"
    }
}

extension SQLite {
    /// Process-wide handle store keyed by integer. Handles are global rather
    /// than per-Bridge so multiple stacks could (in theory) share one DB
    /// connection if a future API decided to expose it — today they don't,
    /// but baking pid-of-owner into the bridge would constrain that path.
    final class HandleStore {
        static let shared = HandleStore()
        private init() {}

        private let lock = NSLock()
        private var map: [Int: Connection] = [:]
        private var next: Int = 1

        func mint(_ conn: Connection) -> Int {
            lock.lock(); defer { lock.unlock() }
            let h = next; next += 1
            map[h] = conn
            return h
        }
        func get(_ h: Int) -> Connection? {
            lock.lock(); defer { lock.unlock() }
            return map[h]
        }
        @discardableResult
        func release(_ h: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return map.removeValue(forKey: h) != nil
        }
    }
}
