import Foundation

/// Menubar primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1+A4+A5). Eight entries
/// covering the runtime menubar surface:
///
///   - `menubar.suppress` / `menubar.restore` — refcounted system menu
///     bar hide via MenuBarVisibility. Tokens stack LIFO on
///     `menubarSuppressions`; the scope drain in Bridge.swift cancels
///     anything left at unload so a crashed stack can't leave the bar
///     hidden forever.
///
///   - `menubar.addItem` — async on main; mints an id, builds the
///     StatusItemSpec via `Bridge.parseStatusItemSpec`, calls
///     `Menubar.addItem` which creates the NSStatusItem, and wires
///     onClick / onMenuPick back to JS via
///     `bridge.dispatchMenubarEvent` (which fires `__sd_menubar_event`).
///     Per-stack scope removes orphans on unload.
///
///   - `menubar.item.{setTitle, setIcon, setMenu, setTooltip, remove}` —
///     mutators against an already-minted handle, looked up via the id
///     returned from `addItem`. `setIcon` re-parses an IconSpec dict via
///     `Bridge.parseIconSpec`; `remove` pops the handle out of
///     `statusItems` and calls `handle.remove()` synchronously.
///
///   - `menubar.items` — read-only AX walk of every visible menubar
///     status item via `MenubarItems.items()`. Folded under the existing
///     "menubar" permission (same gate as suppress/restore + the
///     menubar.observe channel).
///
/// `menubarSuppressions`, `statusItems`, `nextStatusItemId` were widened
/// from private/fileprivate to internal in Bridge.swift so this file's
/// `.syncBridge` / `.custom` closures can mint and release handles. The
/// `dispatchMenubarEvent` helper and the `parseStatusItemSpec` /
/// `parseIconSpec` parsers were widened from fileprivate to internal for
/// the same reason. Scope drain on stack unload (in Bridge.swift) cancels
/// every still-active suppression and removes every NSStatusItem so a
/// hot-reload doesn't leak.
///
/// NOTE: only the JS-bound runtime API moved here. Manifest-driven
/// menubar startup wiring (`startMenubarItems()` called from
/// `start(manifest:)` when the manifest declares the "menubar" permission)
/// stays in Bridge.swift — same separation as static manifest hotkeys vs
/// `sd.hotkey.bind`.
extension Bridge {
    /// Menubar primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func menubarPrimitives() -> [Primitive] {
        return [
            // Menubar suppression — refcounted via per-Bridge stack of tokens.
            .syncBridge("menubar.suppress", permission: "menubar", denyValue: false) { bridge, _ in
                guard let token = MenuBarVisibility.suppress() else { return false }
                bridge.menubarSuppressions.append(token)
                return true
            },
            .syncBridge("menubar.restore", permission: "menubar", denyValue: false) { bridge, _ in
                guard let t = bridge.menubarSuppressions.popLast() else { return false }
                t.cancel(); return true
            },

            // ── Menubar items (NSStatusItem) ─────────────────────────────────────
            // addItem mints an id, creates the NSStatusItem on main, wires click /
            // menu-pick callbacks back to JS via __sd_menubar_event. Per-stack
            // scope removes orphans on unload. New permission: "menubar.item",
            // distinct from "menubar" (which gates suppress/restore).
            .custom("menubar.addItem", permission: "menubar.item") { bridge, body, requestId in
                DispatchQueue.main.async { [weak bridge] in
                    guard let bridge = bridge else { return }
                    let id = bridge.nextStatusItemId
                    bridge.nextStatusItemId += 1
                    let spec = Bridge.parseStatusItemSpec(body)
                    let handle = Menubar.addItem(id: id, spec: spec)
                    handle.onClick = { [weak bridge] in
                        bridge?.dispatchMenubarEvent(itemId: id, type: "click", payload: nil)
                    }
                    handle.onMenuPick = { [weak bridge] pickId in
                        bridge?.dispatchMenubarEvent(itemId: id, type: "pick", payload: pickId)
                    }
                    bridge.statusItems[id] = handle
                    bridge.respond(requestId: requestId, value: id)
                }
            },
            .syncBridge("menubar.item.setTitle", permission: "menubar.item", denyValue: false) { b, body in
                guard let id = body["id"] as? Int, let h = b.statusItems[id] else { return false }
                h.setTitle(body["title"] as? String)
                return true
            },
            .syncBridge("menubar.item.setIcon", permission: "menubar.item", denyValue: false) { b, body in
                guard let id = body["id"] as? Int, let h = b.statusItems[id] else { return false }
                let iconDict = body["icon"] as? [String: Any]
                h.setIcon(iconDict.map(Bridge.parseIconSpec))
                return true
            },
            .syncBridge("menubar.item.setMenu", permission: "menubar.item", denyValue: false) { b, body in
                guard let id = body["id"] as? Int, let h = b.statusItems[id] else { return false }
                h.setMenu(body["items"] as? [[String: Any]])
                return true
            },
            .syncBridge("menubar.item.setTooltip", permission: "menubar.item", denyValue: false) { b, body in
                guard let id = body["id"] as? Int, let h = b.statusItems[id] else { return false }
                h.setTooltip(body["tooltip"] as? String)
                return true
            },
            .syncBridge("menubar.item.remove", permission: "menubar.item", denyValue: false) { b, body in
                guard let id = body["id"] as? Int, let h = b.statusItems.removeValue(forKey: id) else { return false }
                h.remove()
                return true
            },

            // Read-only AX walk of every visible menubar status item. Used by
            // menubar-manager stacks to enumerate what's in the bar — third-
            // party app icons + Apple's Spotlight + clock. macOS 14+ Control
            // Center cluster lives in a separate AXSystemUIServer process and
            // is not enumerable from systemWide; documented as a limitation.
            // Folded under the existing "menubar" permission (same gate as
            // suppress/restore + the menubar.observe channel).
            .sync("menubar.items", permission: "menubar", denyValue: [[String: Any]]()) { _ in
                MenubarItems.items()
            },
        ]
    }
}
