import Foundation

/// SQLite primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1+A4). Four entries:
///
///   - `sqlite.open` — opens a connection via the process-wide
///     `SQLite.HandleStore`. The returned `handle` Int is recorded in the
///     per-Bridge `sqliteHandles` set so stack unload closes any forgotten
///     connections; ownership is per-Bridge but the underlying handle store
///     is global.
///
///   - `sqlite.exec` / `sqlite.query` — pure pass-through to libsqlite3
///     (write-style / read-style). No bridge state read or mutated; the
///     `_` placeholder in the closure signature is the unused Bridge.
///
///   - `sqlite.close` — removes the handle from the per-Bridge set before
///     calling `SQLite.close(handle:)`, so the scope drain on unload
///     doesn't try to close an already-closed handle.
///
/// `sqliteHandles` was widened from fileprivate to internal in Bridge.swift
/// so this file's `.syncBridge` closures can mint and release SQLite
/// handles. Default path lands under ~/stackd/stacks/<id>/data/
/// (sandbox-style); absolute paths and ~ paths pass through.
extension Bridge {
    /// SQLite primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func sqlitePrimitives() -> [Primitive] {
        return [
            // Minimal libsqlite3 wrapper — open / exec / query / close.
            // Default path lands under ~/stackd/stacks/<id>/data/
            // (sandbox-style); absolute paths and ~ paths pass through.
            // Handles are integers minted by a process-wide store but
            // ownership is per-Bridge so unload closes every connection.
            // Permission: "sqlite".
            .syncBridge("sqlite.open", permission: "sqlite") { b, body in
                let path = body["path"] as? String ?? ""
                let mode = body["mode"] as? String ?? "readwrite"
                guard let result = SQLite.open(stackId: b.stackId, path: path, mode: mode) else {
                    return NSNull()
                }
                if let h = result["handle"] as? Int { b.sqliteHandles.insert(h) }
                return result
            },
            .syncBridge("sqlite.exec", permission: "sqlite") { _, body in
                SQLite.exec(
                    handle: body["handle"] as? Int ?? -1,
                    sql:    body["sql"]    as? String ?? "")
            },
            .syncBridge("sqlite.query", permission: "sqlite") { _, body in
                SQLite.query(
                    handle: body["handle"] as? Int ?? -1,
                    sql:    body["sql"]    as? String ?? "",
                    params: body["params"] as? [Any] ?? [])
            },
            .syncBridge("sqlite.close", permission: "sqlite", denyValue: false) { b, body in
                guard let h = body["handle"] as? Int else { return false }
                b.sqliteHandles.remove(h)
                return SQLite.close(handle: h)
            },
        ]
    }
}
