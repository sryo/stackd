import Foundation

/// Broadcasts primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1+A4). Two entries:
///
///   - `broadcasts.observe` — mints an id, registers an
///     NSDistributedNotificationCenter observer via `Broadcasts.observe`,
///     fires `__sd_broadcast_fire(id, payload)` into the stack's WebView
///     from the notification callback. Complements Caffeinate (which
///     hard-codes `screenIsLocked` / `screenIsUnlocked`) — here the stack
///     picks the notification name.
///
///   - `broadcasts.unobserve` — cancels the Token (removes the observer)
///     and drops the id from `broadcastTokens`. Idempotent: a second
///     unobserve on the same id reports false.
///
/// `broadcastTokens` and `nextBroadcastId` were widened from fileprivate
/// to internal in Bridge.swift so this file's `.custom` / `.syncBridge`
/// closures can mint and release DN observers. Scope drain on stack
/// unload (end of Bridge.swift) drops every observer this stack
/// registered with DistributedNotificationCenter.
extension Bridge {
    /// Broadcasts primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func broadcastsPrimitives() -> [Primitive] {
        return [
            // ── Generic NSDistributedNotificationCenter observer ─────────────────
            // Complements Caffeinate (which hard-codes screenIsLocked / screenIsUnlocked):
            // here the stack picks the notification name. Same mint-id + window-global
            // fire pattern as hotkey.bind. Permission: "broadcasts".
            .custom("broadcasts.observe", permission: "broadcasts") { bridge, body, requestId in
                guard let name = body["name"] as? String else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                let id = bridge.nextBroadcastId
                bridge.nextBroadcastId += 1
                let token = Broadcasts.observe(name: name) { [weak bridge] payload in
                    guard let webView = bridge?.webView else { return }
                    let json = Bridge.jsonify(payload)
                    DispatchQueue.main.async {
                        webView.evaluateJavaScript("window.__sd_broadcast_fire && window.__sd_broadcast_fire(\(id), \(json));",
                                                   completionHandler: nil)
                    }
                }
                bridge.broadcastTokens[id] = token
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("broadcasts.unobserve", permission: "broadcasts", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let t = b.broadcastTokens.removeValue(forKey: id) else { return false }
                t.cancel()
                return true
            },
        ]
    }
}
