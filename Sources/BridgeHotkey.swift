import Foundation

/// Hotkey primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1+A4). Five entries
/// covering the JS-driven Carbon hotkey surface:
///
///   - `hotkey.bind` — mints an id, registers a Carbon hot key via
///     `HotkeyRegistry`, fires `__sd_hotkey_fire(id)` into the stack's
///     WebView from the Carbon callback. Optional `mode` / `apps` /
///     `excludeApps` mirror skhd-style scoping; all nil = always-on.
///
///   - `hotkey.unbind` — cancels the Token (deregisters the Carbon
///     binding) and removes the id from `hotkeyTokens`. Idempotent: a
///     second unbind on the same id reports false.
///
///   - `hotkey.mode.{enter,exit,current}` — manipulates the GLOBAL
///     skhd-style mode string on `HotkeyRegistry`. Bindings with no mode
///     declared stay always-on so the chord that exits the mode itself
///     can be expressed. Mode is a single string shared across stacks,
///     matching skhd's "the keyboard is one resource" model.
///
/// `hotkeyTokens` and `nextHotkeyId` were widened from fileprivate to
/// internal in Bridge.swift so this file's `.custom` / `.syncBridge`
/// closures can mint and release Carbon registrations. Scope drain on
/// stack unload (end of Bridge.swift) cancels every still-bound chord
/// so reload doesn't leak duplicate registrations.
///
/// NOTE: only the JS-bound runtime API lives here. Static manifest-driven
/// hotkey wiring (StackManifest → HotkeyRegistry at stack load) stays in
/// StackHost — same separation as bangs vs `sd.bang.*`.
extension Bridge {
    /// Hotkey primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func hotkeyPrimitives() -> [Primitive] {
        return [
            // ── Dynamic hotkey bind/unbind from JS ───────────────────────────────
            // Static manifest hotkeys cover the common case; this lets palettes /
            // modal stacks register transient chords on demand (Palette verb mode,
            // ChoiceBox, ForceKeys). Returns the id on success, null on parse error.
            // Gated on "hotkey" permission so dynamic registration is auditable
            // (manifest hotkeys are already inspectable in stack.json).
            .custom("hotkey.bind", permission: "hotkey") { bridge, body, requestId in
                guard let spec = body["spec"] as? String else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                // Optional skhd-style scoping. `mode` gates dispatch on the
                // active HotkeyRegistry mode; `apps` whitelists the frontmost
                // app's bundleID; `excludeApps` blacklists it. All nil = current
                // always-on behavior. apps + excludeApps compose (both must pass).
                let mode = body["mode"] as? String
                let apps = body["apps"] as? [String]
                let excludeApps = body["excludeApps"] as? [String]
                let id = bridge.nextHotkeyId
                bridge.nextHotkeyId += 1
                let token = HotkeyRegistry.shared.bind(
                    spec: spec, mode: mode, apps: apps, excludeApps: excludeApps
                ) { [weak bridge] in
                    // Fire on the same hop pattern as fireBang / fireHotkey — the
                    // Carbon callback already runs on main, but the eval has to be
                    // async to keep main from re-entering JS while a script is mid-flight.
                    guard let webView = bridge?.webView else { return }
                    DispatchQueue.main.async {
                        webView.evaluateJavaScript("window.__sd_hotkey_fire && window.__sd_hotkey_fire(\(id));",
                                                   completionHandler: nil)
                    }
                }
                guard let token = token else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                bridge.hotkeyTokens[id] = token
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("hotkey.unbind", permission: "hotkey", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let token = b.hotkeyTokens.removeValue(forKey: id) else { return false }
                token.cancel()
                return true
            },

            // Modal keymaps (skhd). Entering a mode suppresses every binding
            // declared for a different mode until exit; bindings with no mode
            // declared (mode == nil) stay always-on so the chord that exits the
            // mode itself can be expressed. Mode is GLOBAL — a single string
            // shared across stacks, matching skhd's "the keyboard is one
            // resource" model. Folded under the existing "hotkey" permission.
            .sync("hotkey.mode.enter", permission: "hotkey", denyValue: false) { body in
                guard let name = body["name"] as? String else { return false }
                HotkeyRegistry.shared.enterMode(name)
                return true
            },
            .sync("hotkey.mode.exit", permission: "hotkey", denyValue: false) { _ in
                HotkeyRegistry.shared.exitMode()
                return true
            },
            .sync("hotkey.mode.current", permission: "hotkey") { _ in
                HotkeyRegistry.shared.currentMode
            },
        ]
    }
}
