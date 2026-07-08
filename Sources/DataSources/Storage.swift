import Foundation
import CoreServices
import AppKit
import SQLite3
import Darwin

// Storage: files / settings / clipboard / sqlite — all the "remember things on
// disk or in memory" surfaces collapsed into a single domain file.
//
// Folds in (per rearchitecture-unified.md §1 + R2f):
//   - FS         → enum FS, final class FSWatch
//   - Settings   → final class StackSettings
//   - Defaults   → enum Defaults
//   - Pasteboard → enum Pasteboard, final class PasteboardObserver
//   - SQLite     → enum SQLite (+ Connection, HandleStore)
//
// Enum / class names are preserved verbatim because Bridge.swift dispatches
// by name, StackSettings is consumed directly by Bridge.start, and
// PasteboardObserver is the standard RefCountedObserver subclass pattern.

// MARK: - FS

// Filesystem as a data source: read/stat/list (imperative) + watch (push).
// FileWatcher.swift is internal-only (drives the daemon's auto-reload);
// this file exposes the same FSEventStream machinery to stacks per-watch.

enum FS {
    /// Read file contents. `encoding` selects how bytes land in JS:
    ///   - "utf8"   (default) → UTF-8 decoded string, nil if not valid UTF-8.
    ///   - "base64" → base64-encoded blob, binary-safe (PNG, plist, .ds_store).
    /// Anything else falls back to utf8. Returns nil if the file can't be
    /// read at all (missing path, permission denied, etc).
    static func read(path: String, encoding: String = "utf8") -> String? {
        let p = expand(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
            return nil
        }
        if encoding == "base64" {
            return data.base64EncodedString()
        }
        return String(data: data, encoding: .utf8)
    }

    static func stat(path: String) -> [String: Any]? {
        let p = expand(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { return nil }
        var out: [String: Any] = [
            "path":   p,
            "size":   (attrs[.size] as? Int) ?? 0,
            "isDir":  (attrs[.type] as? FileAttributeType) == .typeDirectory
        ]
        if let date = attrs[.modificationDate] as? Date {
            out["mtime"] = date.timeIntervalSince1970
        }
        return out
    }

    static func list(dir: String, includeHidden: Bool = false) -> [String]? {
        let p = expand(dir)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: p) else { return nil }
        return includeHidden ? items : items.filter { !$0.hasPrefix(".") }
    }

    /// Atomic write: writes to a sibling temp file, then renames over the
    /// destination. Prevents half-written files from being read by other
    /// processes or our own FSEvents-driven reloaders. Returns true on success.
    @discardableResult
    static func write(path: String, contents: String) -> Bool {
        let p = expand(path)
        let url = URL(fileURLWithPath: p)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// mkdir -p equivalent. Returns true if the directory exists after the call.
    @discardableResult
    static func mkdir(path: String) -> Bool {
        let p = expand(path)
        do {
            try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            return true
        } catch {
            // createDirectory throws if it already exists as a file (not dir);
            // also throws if mid-tree component is non-dir. Check existence
            // to distinguish a real failure from "already there".
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Removes a file or directory. Recursive for directories. Returns true if
    /// the path no longer exists after the call. No-op if it wasn't there.
    @discardableResult
    static func delete(path: String) -> Bool {
        let p = expand(path)
        if !FileManager.default.fileExists(atPath: p) { return true }
        do {
            try FileManager.default.removeItem(atPath: p)
            return true
        } catch {
            return false
        }
    }

    /// Atomic rename. Fails if the destination already exists; callers should
    /// delete first if they want overwrite semantics.
    @discardableResult
    static func move(from: String, to: String) -> Bool {
        let src = expand(from)
        let dst = expand(to)
        do {
            try FileManager.default.moveItem(atPath: src, toPath: dst)
            return true
        } catch {
            return false
        }
    }

    /// Expand ~ and ~user prefixes. Other paths pass through.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

// MARK: - Xattr

// Extended-attribute access via the Darwin syscalls. Raw byte payloads
// round-trip as base64 strings so binary plist blobs (Finder tags under
// `com.apple.metadata:_kMDItemUserTags`, download provenance under
// `com.apple.metadata:kMDItemWhereFroms`) survive the IPC.
//
// No auto-decoding in v1 — callers that want a readable tag list run the
// returned bytes through atob() + a plist parser. See audit §5b A5 for
// the rationale (binary-plist decoding lives in stack code, not the daemon).
enum Xattr {
    /// Read the named xattr. Returns base64-encoded bytes on success,
    /// nil if the attribute doesn't exist or the path can't be read.
    static func get(path: String, name: String) -> String? {
        let p = FS.expand(path)
        // Two-call dance: ask for size first (size=0 + null buf), then read.
        let size = getxattr(p, name, nil, 0, 0, 0)
        if size < 0 { return nil }
        if size == 0 { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        let n = getxattr(p, name, &buf, size, 0, 0)
        if n < 0 { return nil }
        return Data(buf[0..<n]).base64EncodedString()
    }

    /// Set the named xattr. `value` is base64-encoded bytes; bad base64
    /// returns false without touching the filesystem. Replaces any
    /// existing value (XATTR_REPLACE not used).
    @discardableResult
    static func set(path: String, name: String, value: String) -> Bool {
        let p = FS.expand(path)
        guard let data = Data(base64Encoded: value) else { return false }
        let rc = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            setxattr(p, name, raw.baseAddress, data.count, 0, 0)
        }
        return rc == 0
    }

    /// List xattr names on `path`. Returns [] when no xattrs are set,
    /// nil if the path can't be read.
    static func list(path: String) -> [String]? {
        let p = FS.expand(path)
        let size = listxattr(p, nil, 0, 0)
        if size < 0 { return nil }
        if size == 0 { return [] }
        var buf = [CChar](repeating: 0, count: size)
        let n = listxattr(p, &buf, size, 0)
        if n < 0 { return nil }
        // listxattr returns NUL-separated names with a trailing NUL.
        var names: [String] = []
        var start = 0
        for i in 0..<n {
            if buf[i] == 0 {
                if i > start {
                    let slice = Array(buf[start..<i]) + [0]
                    names.append(String(cString: slice))
                }
                start = i + 1
            }
        }
        return names
    }

    /// Remove the named xattr. Returns true on success, false if the
    /// attribute didn't exist or the path can't be written.
    @discardableResult
    static func remove(path: String, name: String) -> Bool {
        let p = FS.expand(path)
        return removexattr(p, name, 0) == 0
    }
}

/// One FSWatch per active sd.fs.watch subscription. Lifetime owned by Bridge
/// (held in a [watchId: FSWatch] map). Deinit tears the FSEventStream down.
final class FSWatch {
    private var stream: FSEventStreamRef?
    private let callback: ([(path: String, flags: FSEventStreamEventFlags)]) -> Void

    init?(paths: [String], callback: @escaping ([(path: String, flags: FSEventStreamEventFlags)]) -> Void) {
        self.callback = callback
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, numEvents, evPaths, evFlags, _ in
            guard let info = info else { return }
            let watch = Unmanaged<FSWatch>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes set, evPaths is a
            // CFArrayRef of CFStringRef. Without that flag it would be a
            // raw `UnsafePointer<UnsafePointer<CChar>?>` and the NSArray
            // bridge would interpret the first 8 bytes of a path string
            // as an object pointer → EXC_BAD_ACCESS on the next message
            // send.
            let cfPaths = Unmanaged<CFArray>.fromOpaque(evPaths).takeUnretainedValue()
            let paths = (cfPaths as NSArray) as? [String] ?? []
            let flagsBuf = UnsafeBufferPointer(start: evFlags, count: numEvents)
            var events: [(path: String, flags: FSEventStreamEventFlags)] = []
            for i in 0..<min(paths.count, flagsBuf.count) {
                events.append((path: paths[i], flags: flagsBuf[i]))
            }
            watch.callback(events)
        }
        let cfPaths = paths.map { FS.expand($0) } as CFArray
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, cb, &ctx,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }
        self.stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    deinit { stop() }

    /// Decode the FSEventStream flags into a stable human-readable kind string.
    /// Multiple bits can be set; we report the most-meaningful one.
    static func kindFor(flags: FSEventStreamEventFlags) -> String {
        let f = Int(flags)
        if f & kFSEventStreamEventFlagItemRemoved   != 0 { return "removed"   }
        if f & kFSEventStreamEventFlagItemCreated   != 0 { return "created"   }
        if f & kFSEventStreamEventFlagItemRenamed   != 0 { return "renamed"   }
        if f & kFSEventStreamEventFlagItemModified  != 0 { return "modified"  }
        if f & kFSEventStreamEventFlagItemInodeMetaMod != 0 { return "meta"   }
        if f & kFSEventStreamEventFlagItemXattrMod  != 0 { return "xattr"     }
        return "changed"
    }
}

// MARK: - Settings

// Per-stack scoped k/v persistence backed by UserDefaults suites.
// Each stack gets its own namespace at `com.stackd.stack.<id>`, isolated
// from every other stack. Stored values are plist-compatible — i.e.
// anything JSON-serializable (String, Number, Bool, Array, Dict, null).
//
// Why a per-stack suite instead of one shared bucket with prefixed keys:
// - cleaner deletion (suite-wide reset)
// - shows up as its own group in `defaults` CLI for debugging
// - no key-collision worries between stacks
final class StackSettings {
    let suite: UserDefaults
    let stackId: String

    init(stackId: String) {
        self.stackId = stackId
        self.suite = UserDefaults(suiteName: "com.stackd.stack.\(stackId)") ?? .standard
    }

    func get(_ key: String) -> Any? {
        return suite.object(forKey: key)
    }

    func set(_ key: String, _ value: Any?) {
        // UserDefaults only stores plist types (String/Number/Bool/Date/Data/
        // Array/Dict). NSNull anywhere in the tree crashes the write. Sanitize
        // recursively — strip NSNull from arrays/dicts, drop top-level NSNull.
        if let v = value, let sanitized = StackSettings.sanitize(v) {
            suite.set(sanitized, forKey: key)
        } else {
            suite.removeObject(forKey: key)
        }
    }

    private static func sanitize(_ v: Any) -> Any? {
        if v is NSNull { return nil }
        if let arr = v as? [Any] {
            return arr.compactMap { sanitize($0) }
        }
        if let dict = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, val) in dict {
                if let san = sanitize(val) { out[k] = san }
            }
            return out
        }
        return v
    }

    func delete(_ key: String) {
        suite.removeObject(forKey: key)
    }

    /// Stack-scoped key set (excludes the global UserDefaults bleed-through).
    /// UserDefaults' dictionaryRepresentation includes everything inherited
    /// from the parents, so we filter to keys actually written to OUR suite.
    func all() -> [String: Any] {
        guard let persistent = suite.persistentDomain(forName: "com.stackd.stack.\(stackId)") else {
            return [:]
        }
        return persistent
    }
}

// MARK: - Defaults

// Imperative read of CFPreferences (the `defaults` command's backend).
// Exposed to JS as `sd.defaults.read(bundleId, key) → Promise<value>` — the
// first request/response shape in stackd (everything else is a signal push).
enum Defaults {
    static func read(bundleId: String, key: String) -> Any? {
        guard let raw = CFPreferencesCopyAppValue(key as CFString, bundleId as CFString) else {
            return nil
        }
        return coerce(raw)
    }

    private static func coerce(_ v: CFTypeRef) -> Any {
        if let s = v as? String  { return s }
        if let b = v as? Bool    { return b }
        if let n = v as? NSNumber { return n }
        if let a = v as? [Any]   { return a.map { coerce($0 as CFTypeRef) } }
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, val) in d { out[k] = coerce(val as CFTypeRef) }
            return out
        }
        return String(describing: v)
    }
}

// MARK: - Pasteboard

enum Pasteboard {
    static func getString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    @discardableResult
    static func setString(_ s: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(s, forType: .string)
    }

    static var changeCount: Int { NSPasteboard.general.changeCount }
}

/// Pasteboard-change observer.
///
/// Primary: `com.apple.pasteboard.notify.changed` distributed notification.
/// AppKit's pasteboard write path posts this on Sonoma/Sequoia (and
/// likely earlier); event-driven so a paste fires the callback within ~50ms
/// instead of waiting for the next poll tick.
///
/// Safety net: a 1.5s timer with the existing `changeCount` dedup. Catches
/// (a) macOS versions or write paths that don't fire the DN, (b) any future
/// rename of the notification. 1.5s vs the previous 0.2s is 7.5× fewer
/// timer wakeups; combined with the DN on the happy path, idle wakeups
/// drop to one every 1.5s + zero CPU per wakeup when nothing's changed
/// (changeCount is a single Mach property read).
final class PasteboardObserver: RefCountedObserver {
    static let shared = PasteboardObserver()
    private override init() { super.init() }

    private var lastChangeCount: Int = 0

    override func install() -> Token {
        lastChangeCount = NSPasteboard.general.changeCount

        // Primary: distributed notification. The `installNotifications` helper
        // on RefCountedObserver wires a Token that removes the observer on
        // teardown — same shape MenubarObserver and others use.
        let dnToken = installNotifications([
            (DistributedNotificationCenter.default(),
             Notification.Name("com.apple.pasteboard.notify.changed"),
             { [weak self] _ in
                 guard let self = self else { return }
                 let cc = NSPasteboard.general.changeCount
                 if cc != self.lastChangeCount {
                     self.lastChangeCount = cc
                     self.fire()
                 }
             })
        ])

        // Safety net: poll changeCount every 1.5s. Catches writes that
        // bypass the DN (rare). Dedup against lastChangeCount keeps the
        // happy path cost-free — one Mach call per wakeup, no fan-out.
        let t = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let cc = NSPasteboard.general.changeCount
            if cc != self.lastChangeCount {
                self.lastChangeCount = cc
                self.fire()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        return Token {
            dnToken.cancel()
            t.invalidate()
        }
    }
}

// MARK: - SQLite

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
