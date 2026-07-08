import Foundation

/// Storage-shaped primitive group — extracted from Bridge.swift as part of
/// the god-object breakup continuation (follow-up to A1+A4+A5). Three
/// k/v-shaped surfaces that cluster naturally:
///
///   - `defaults.read` — one-shot read against another app's
///     `CFPreferences` plist (bundleId + key). Pure DataSources/Storage
///     wrapper; the write side is intentionally absent (cross-app
///     defaults writes would need TCC + sandboxing review).
///
///   - `settings.{get,set,delete,all}` — per-stack key/value store scoped
///     to this Bridge's `StackSettings`. Lazy-initialized inside Bridge
///     when the manifest declares the "settings" permission; the
///     primitives below deny-default to `null` (get) / `false`
///     (set/delete) / `[:]` (all) when the store isn't attached.
///
///   - `pasteboard.{get,set}` — global NSPasteboard string slot. The
///     watch side is event-driven and lives elsewhere (StackHost emits
///     `sd.pasteboard.changed` via `PasteboardObserver`).
///
/// These three sit together because they're all "key/value plumbing": no
/// long-lived handles, no per-stack scope drain, no observer wiring. The
/// only Bridge state touched is `b.settings`, which is owned + lifecycle-
/// managed in Bridge.swift; this file only reads/writes through it via
/// the `.syncBridge` shim.
extension Bridge {
    /// Storage primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func storagePrimitives() -> [Primitive] {
        return [
            // Defaults — one-shot read against another app's CFPreferences
            // plist. Write side is intentionally absent (cross-app defaults
            // writes would need TCC + sandboxing review).
            .sync("defaults.read", permission: "defaults") { body in
                Defaults.read(bundleId: body["bundleId"] as? String ?? "",
                              key:      body["key"]      as? String ?? "")
            },

            // Per-stack settings (k/v scoped to this stack's id). Write-style ops
            // (set/delete) deny → false; get → null; all → empty dict.
            .syncBridge("settings.get",    permission: "settings") { b, body in b.settings?.get(body["key"] as? String ?? "") as Any? },
            .syncBridge("settings.set",    permission: "settings", denyValue: false) { b, body in b.settings?.set(body["key"] as? String ?? "", body["value"]); return true },
            .syncBridge("settings.delete", permission: "settings", denyValue: false) { b, body in b.settings?.delete(body["key"] as? String ?? ""); return true },
            .syncBridge("settings.all",    permission: "settings", denyValue: [String: Any]()) { b, _ in b.settings?.all() ?? [:] },

            // Pasteboard — global NSPasteboard string slot. The watch side
            // is event-driven and lives elsewhere (sd.pasteboard.changed
            // channel pushed by PasteboardObserver).
            .sync("pasteboard.get", permission: "pasteboard") { _ in Pasteboard.getString() },
            .sync("pasteboard.set", permission: "pasteboard", denyValue: false) { body in
                Pasteboard.setString(body["value"] as? String ?? "")
            },
        ]
    }
}
