import Foundation

// Tests for Storage.swift — the "remember things on disk" domain (FS / Xattr /
// StackSettings / Defaults / Pasteboard / SQLite). Two layers worth testing:
//
//   1. StackSettings round-trip. The UserDefaults suite-name composition
//      ("com.stackd.stack.<id>") + NSNull sanitization are bug-prone:
//      NSNull anywhere in a nested array/dict crashes the plist writer if
//      it leaks through. We hammer the sanitize path indirectly via set/get
//      using a UUID-prefixed suite so the user's real defaults stay untouched.
//
//   2. SQLite. Path resolution (":memory:" / absolute / per-stack default),
//      mode parsing (readonly vs rw+create), and the typed parameter binding
//      (Int / Double / Bool / String / NSNull → typed SQLITE_*). Best lever:
//      open a real :memory: connection so we don't leave temp files behind,
//      then exec + query against it. Real bug surface, zero disk footprint.
//
// FS.expand and the global Pasteboard / Xattr surfaces touch user state
// (real ~ expansion is fine; pasteboard mutation isn't) — we only exercise
// the pure / temp-scoped corners here.

func registerStorageTests() {
    // MARK: - StackSettings (per-stack UserDefaults suite)

    test("StackSettings round-trips primitive + dict values in an isolated suite") {
        // UUID-prefixed stackId → unique suite name; cleaned up at the end so
        // we never pollute com.stackd.stack.* with test debris.
        let stackId = "test-\(UUID().uuidString)"
        let settings = StackSettings(stackId: stackId)
        defer {
            settings.suite.removePersistentDomain(forName: "com.stackd.stack.\(stackId)")
        }

        settings.set("greeting", "hello")
        settings.set("count", 42)
        settings.set("nested", ["a": 1, "b": "two"] as [String: Any])

        try expectEqual(settings.get("greeting") as? String, "hello")
        try expectEqual(settings.get("count") as? Int, 42)
        guard let nested = settings.get("nested") as? [String: Any] else {
            throw Expectation(message: "nested dict missing after round-trip")
        }
        try expectEqual(nested["a"] as? Int, 1)
        try expectEqual(nested["b"] as? String, "two")
    }

    test("StackSettings.set with NSNull at top level deletes the key") {
        // The sanitize path returns nil for top-level NSNull → set should
        // route through removeObject rather than crashing the plist writer.
        let stackId = "test-\(UUID().uuidString)"
        let settings = StackSettings(stackId: stackId)
        defer {
            settings.suite.removePersistentDomain(forName: "com.stackd.stack.\(stackId)")
        }

        settings.set("k", "initial")
        try expectEqual(settings.get("k") as? String, "initial")

        settings.set("k", NSNull())
        try expect(settings.get("k") == nil, "expected nil after NSNull set, got \(String(describing: settings.get("k")))")
    }

    test("StackSettings.set strips NSNull from nested arrays and dicts") {
        // The sanitize recursion must drop NSNull from inside arrays and
        // dicts — UserDefaults' plist writer crashes if any leak through.
        let stackId = "test-\(UUID().uuidString)"
        let settings = StackSettings(stackId: stackId)
        defer {
            settings.suite.removePersistentDomain(forName: "com.stackd.stack.\(stackId)")
        }

        let mixed: [Any] = ["a", NSNull(), "b", NSNull(), 3]
        settings.set("arr", mixed)
        guard let out = settings.get("arr") as? [Any] else {
            throw Expectation(message: "array missing after sanitize")
        }
        try expectEqual(out.count, 3)
        try expectEqual(out[0] as? String, "a")
        try expectEqual(out[1] as? String, "b")
        try expectEqual(out[2] as? Int, 3)

        let dict: [String: Any] = ["keep": "yes", "drop": NSNull()]
        settings.set("d", dict)
        guard let outDict = settings.get("d") as? [String: Any] else {
            throw Expectation(message: "dict missing after sanitize")
        }
        try expectEqual(outDict.count, 1)
        try expectEqual(outDict["keep"] as? String, "yes")
        try expect(outDict["drop"] == nil, "NSNull dict value should have been stripped")
    }

    test("StackSettings.all returns only this suite's keys (no global bleed-through)") {
        // dictionaryRepresentation would include every inherited default;
        // all() must filter to keys actually written into our suite.
        let stackId = "test-\(UUID().uuidString)"
        let settings = StackSettings(stackId: stackId)
        defer {
            settings.suite.removePersistentDomain(forName: "com.stackd.stack.\(stackId)")
        }

        settings.set("one", 1)
        settings.set("two", "2")
        let all = settings.all()
        try expectEqual(all.count, 2)
        try expectEqual(all["one"] as? Int, 1)
        try expectEqual(all["two"] as? String, "2")
    }

    test("StackSettings suites are isolated across stack ids") {
        // Two different stackIds → two different suites; writes don't bleed.
        let idA = "test-\(UUID().uuidString)"
        let idB = "test-\(UUID().uuidString)"
        let a = StackSettings(stackId: idA)
        let b = StackSettings(stackId: idB)
        defer {
            a.suite.removePersistentDomain(forName: "com.stackd.stack.\(idA)")
            b.suite.removePersistentDomain(forName: "com.stackd.stack.\(idB)")
        }

        a.set("shared-key", "from-a")
        b.set("shared-key", "from-b")
        try expectEqual(a.get("shared-key") as? String, "from-a")
        try expectEqual(b.get("shared-key") as? String, "from-b")
    }

    // MARK: - SQLite

    test("SQLite.open with :memory: returns a usable handle and reports the path") {
        // :memory: bypasses resolvePath's per-stack landing entirely — the
        // returned path should echo the literal sentinel.
        guard let opened = SQLite.open(stackId: "test", path: ":memory:", mode: "rwc") else {
            throw Expectation(message: "open(:memory:) returned nil")
        }
        guard let handle = opened["handle"] as? Int else {
            throw Expectation(message: "missing handle on open result")
        }
        try expectEqual(opened["path"] as? String, ":memory:")
        try expect(SQLite.close(handle: handle), "close should release minted handle")
    }

    test("SQLite.exec + query round-trip preserves typed parameters") {
        // The bind switch dispatches on Swift type: Int → int64, Double →
        // double, Bool → int(0/1), String → text, NSNull → NULL. We push
        // one of each through and pull them back out via SELECT, asserting
        // the column-type decoding lands on the right Swift kind.
        guard let opened = SQLite.open(stackId: "test", path: ":memory:", mode: "rwc"),
              let handle = opened["handle"] as? Int else {
            throw Expectation(message: "could not open :memory: db")
        }
        defer { _ = SQLite.close(handle: handle) }

        let create = SQLite.exec(handle: handle, sql: """
            CREATE TABLE t (i INTEGER, d REAL, s TEXT, b INTEGER, n TEXT);
            """)
        try expectEqual(create["ok"] as? Bool, true)

        let insert = SQLite.query(
            handle: handle,
            sql: "INSERT INTO t (i, d, s, b, n) VALUES (?, ?, ?, ?, ?)",
            params: [7, 2.5, "hi", true, NSNull()]
        )
        try expectEqual(insert["ok"] as? Bool, true)
        try expectEqual(insert["rowsAffected"] as? Int, 1)
        try expect((insert["lastInsertId"] as? Int) ?? 0 > 0, "lastInsertId should be set after INSERT")

        let select = SQLite.query(handle: handle, sql: "SELECT i, d, s, b, n FROM t", params: [])
        try expectEqual(select["ok"] as? Bool, true)
        guard let rows = select["rows"] as? [[String: Any]], let row = rows.first else {
            throw Expectation(message: "no rows returned")
        }
        try expectEqual(row["i"] as? Int, 7)
        try expectEqual(row["d"] as? Double, 2.5)
        try expectEqual(row["s"] as? String, "hi")
        try expectEqual(row["b"] as? Int, 1) // Bool true → 1
        try expect(row["n"] is NSNull, "NULL column should decode to NSNull, got \(String(describing: row["n"]))")
    }

    test("SQLite.exec returns ok=false with an error message on bad SQL") {
        // Parser errors must surface as { ok: false, error: "..." } rather
        // than crashing or returning a misleading rowsAffected.
        guard let opened = SQLite.open(stackId: "test", path: ":memory:", mode: "rwc"),
              let handle = opened["handle"] as? Int else {
            throw Expectation(message: "could not open :memory: db")
        }
        defer { _ = SQLite.close(handle: handle) }

        let result = SQLite.exec(handle: handle, sql: "NOT VALID SQL;")
        try expectEqual(result["ok"] as? Bool, false)
        try expect(result["error"] is String, "expected error string on bad SQL")
    }

    test("SQLite.exec / query / close return invalid-handle error for stale handles") {
        // Once close() releases a handle, subsequent ops must short-circuit
        // with { ok: false, error: "invalid handle" } instead of dereferencing
        // a freed Connection.
        guard let opened = SQLite.open(stackId: "test", path: ":memory:", mode: "rwc"),
              let handle = opened["handle"] as? Int else {
            throw Expectation(message: "could not open :memory: db")
        }
        try expect(SQLite.close(handle: handle), "first close should succeed")
        try expect(!SQLite.close(handle: handle), "double-close should return false")

        let execResult = SQLite.exec(handle: handle, sql: "SELECT 1")
        try expectEqual(execResult["ok"] as? Bool, false)
        try expectEqual(execResult["error"] as? String, "invalid handle")

        let queryResult = SQLite.query(handle: handle, sql: "SELECT 1", params: [])
        try expectEqual(queryResult["ok"] as? Bool, false)
        try expectEqual(queryResult["error"] as? String, "invalid handle")
    }

    test("SQLite.open honors absolute paths and creates the parent dir") {
        // resolvePath: absolute paths (start with "/") pass through verbatim,
        // and open's parent-mkdir step must materialize a nonexistent dir.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("stackd-storage-tests-\(UUID().uuidString)", isDirectory: true)
        let dbPath = base.appendingPathComponent("nested/db.sqlite").path
        defer { try? FileManager.default.removeItem(at: base) }

        guard let opened = SQLite.open(stackId: "test", path: dbPath, mode: "rwc"),
              let handle = opened["handle"] as? Int else {
            throw Expectation(message: "open with absolute path returned nil")
        }
        defer { _ = SQLite.close(handle: handle) }
        try expectEqual(opened["path"] as? String, dbPath)
        try expect(FileManager.default.fileExists(atPath: dbPath), "expected sqlite file to exist at \(dbPath)")
    }

    test("SQLite.open with mode=readonly fails on a nonexistent path") {
        // SQLITE_OPEN_READONLY without CREATE → open must fail (returns nil)
        // rather than silently materializing an empty db.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("stackd-storage-tests-\(UUID().uuidString)", isDirectory: true)
        let dbPath = base.appendingPathComponent("missing.sqlite").path
        defer { try? FileManager.default.removeItem(at: base) }

        let opened = SQLite.open(stackId: "test", path: dbPath, mode: "readonly")
        try expect(opened == nil, "readonly open of nonexistent file should return nil, got \(String(describing: opened))")
        try expect(!FileManager.default.fileExists(atPath: dbPath), "readonly open should not create the file")
    }
}
