import Foundation

/// Filesystem primitive group — extracted from Bridge.swift as part of the
/// A1 god-object breakup (architect finding #1). Two clusters live here:
///
///   1. **One-shot ops** — `fs.read` / `fs.stat` / `fs.list` / `fs.write` /
///      `fs.mkdir` / `fs.delete` / `fs.move`. Pure `.sync(...)` into
///      `Sources/FileWatcher.swift` (the `FS` namespace). No Bridge state
///      captured.
///
///   2. **Watch lifecycle** — `fs.watch.start` / `fs.watch.stop`. These
///      mint `FSWatch` handles keyed by JS-supplied watchId into
///      `Bridge.fsWatches`. Events fan out through
///      `bridge.dispatchFsEvents(watchId:events:)` which JS resolves to the
///      `__sd_fs_event` global. Scope drain on stack unload stops every
///      surviving watch.
///
///   3. **Extended attributes** — `fs.xattr.get/set/list/remove`. Pure
///      `.sync(...)` into the `Xattr` namespace (lives in
///      `Sources/FileWatcher.swift`). Get returns raw bytes base64-encoded
///      — binary plist payloads survive the IPC; stacks that want a
///      readable tag list parse the binary plist themselves.
///
/// `fsWatches`, `dispatchFsEvents`, and `respond` were widened from
/// fileprivate/private to internal in Bridge.swift to keep these handles
/// pluggable from out-of-file extensions without introducing a re-export
/// shim.
extension Bridge {
    /// FS primitives — concatenated into `Bridge.primitives` alongside the
    /// rest of the inline registrations. Pure builder; no side effects.
    static func fsPrimitives() -> [Primitive] {
        return [
            // Filesystem one-shot ops
            .sync("fs.read", permission: "fs") { body in
                // encoding:
                //   "utf8"   (default) — UTF-8 decoded string, null on non-UTF-8 bytes
                //   "base64" — raw bytes base64-encoded (binary-safe; PNG/plist/etc)
                FS.read(path:     body["path"]     as? String ?? "",
                        encoding: body["encoding"] as? String ?? "utf8")
            },
            .sync("fs.stat", permission: "fs") { body in FS.stat(path: body["path"] as? String ?? "") },
            .sync("fs.list", permission: "fs") { body in
                FS.list(dir: body["dir"] as? String ?? "", includeHidden: body["hidden"] as? Bool ?? false)
            },
            .sync("fs.write", permission: "fs", denyValue: false) { body in
                FS.write(path: body["path"] as? String ?? "", contents: body["contents"] as? String ?? "")
            },
            .sync("fs.mkdir", permission: "fs", denyValue: false) { body in
                FS.mkdir(path: body["path"] as? String ?? "")
            },
            .sync("fs.delete", permission: "fs", denyValue: false) { body in
                FS.delete(path: body["path"] as? String ?? "")
            },
            .sync("fs.move", permission: "fs", denyValue: false) { body in
                FS.move(from: body["from"] as? String ?? "", to: body["to"] as? String ?? "")
            },

            // Watch lifecycle — captures `bridge.fsWatches` (handle store)
            // and `bridge.dispatchFsEvents` (event fanout). Scope drain on
            // stack unload (Bridge.swift, end of file) stops every surviving
            // watch via `for w in fsWatches.values { w.stop() }`.
            .custom("fs.watch.start", permission: "fs", denyValue: false) { bridge, body, requestId in
                let path = body["path"] as? String ?? ""
                let watchId = body["watchId"] as? Int ?? -1
                let watch = FSWatch(paths: [path]) { [weak bridge] events in
                    bridge?.dispatchFsEvents(watchId: watchId, events: events)
                }
                guard let w = watch else { bridge.respond(requestId: requestId, value: false); return }
                bridge.fsWatches[watchId] = w
                bridge.respond(requestId: requestId, value: true)
            },
            .custom("fs.watch.stop", permission: "fs", denyValue: false) { bridge, body, requestId in
                let watchId = body["watchId"] as? Int ?? -1
                if let w = bridge.fsWatches.removeValue(forKey: watchId) {
                    w.stop(); bridge.respond(requestId: requestId, value: true)
                } else {
                    bridge.respond(requestId: requestId, value: false)
                }
            },

            // Extended attributes (com.apple.metadata:*, Finder tags,
            // quarantine, WhereFroms). get returns the raw bytes
            // base64-encoded — binary plist payloads survive the IPC. No
            // auto-decoding in v1; stacks that want a readable tag list
            // parse the binary plist themselves.
            .sync("fs.xattr.get", permission: "fs") { body in
                Xattr.get(path: body["path"] as? String ?? "",
                          name: body["name"] as? String ?? "")
            },
            .sync("fs.xattr.set", permission: "fs", denyValue: false) { body in
                Xattr.set(path:  body["path"]  as? String ?? "",
                          name:  body["name"]  as? String ?? "",
                          value: body["value"] as? String ?? "")
            },
            .sync("fs.xattr.list", permission: "fs") { body in
                Xattr.list(path: body["path"] as? String ?? "") as Any? ?? NSNull()
            },
            .sync("fs.xattr.remove", permission: "fs", denyValue: false) { body in
                Xattr.remove(path: body["path"] as? String ?? "",
                             name: body["name"] as? String ?? "")
            },
        ]
    }
}
