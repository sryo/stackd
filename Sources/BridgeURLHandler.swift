import Foundation

/// URL-handler primitive group — extracted from Bridge.swift as part of
/// the god-object breakup continuation (follow-up to A1+A4). Two entries:
///
///   - `urlhandler.register` — mints an id, subscribes to a `<scheme>://`
///     URL bucket via `URLHandler.observe`, fires
///     `__sd_urlhandler_fire(id, payload)` into the stack's WebView when
///     an event arrives. The NSAppleEventManager GURL handler is
///     installed lazily on first subscribe and stays for the daemon
///     lifetime; per-stack subscribers live in a SchemeRouter bucket and
///     drain on stack unload.
///
///   - `urlhandler.unregister` — cancels the Token (removes this stack's
///     subscriber from the per-scheme bucket) and drops the id. Idempotent.
///
/// Limitation: macOS only ROUTES a custom scheme to stackd if the daemon's
/// Info.plist declares it under CFBundleURLTypes. Today the daemon ships
/// as a plain `.build/stackd` binary (no Info.plist), so the API surface
/// works but URL events won't actually arrive until stackd ships as an
/// `.app` bundle with the scheme declared. See
/// `Sources/DataSources/URLHandler.swift` for the rationale.
///
/// `urlHandlerTokens` and `nextURLHandlerId` were widened from fileprivate
/// to internal in Bridge.swift so this file's `.custom` / `.syncBridge`
/// closures can mint and release scheme subscribers. Scope drain on stack
/// unload drops every per-scheme subscriber this stack added to the
/// process-global SchemeRouter so reload-then-register doesn't leak.
extension Bridge {
    /// URL-handler primitives — concatenated into `Bridge.primitives`
    /// alongside the rest of the inline registrations. Pure builder; no
    /// side effects.
    static func urlHandlerPrimitives() -> [Primitive] {
        return [
            // ── Custom URL scheme handler ──────────────────────────────────────
            // Register a callback for `<scheme>://…` URLs opened by other apps.
            // NSAppleEventManager's GURL handler is installed lazily on first
            // subscribe and stays for the daemon lifetime; per-stack subscribers
            // live in a SchemeRouter bucket and drain on stack unload.
            //
            // Same mint-id + window-global fire pattern as broadcasts.observe.
            // Permission: "urlhandler".
            .custom("urlhandler.register", permission: "urlhandler") { bridge, body, requestId in
                guard let scheme = body["scheme"] as? String, !scheme.isEmpty else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                let id = bridge.nextURLHandlerId
                bridge.nextURLHandlerId += 1
                let token = URLHandler.observe(scheme: scheme) { [weak bridge] payload in
                    guard let webView = bridge?.webView else { return }
                    let json = Bridge.jsonify(payload)
                    DispatchQueue.main.async {
                        webView.evaluateJavaScript("window.__sd_urlhandler_fire && window.__sd_urlhandler_fire(\(id), \(json));",
                                                   completionHandler: nil)
                    }
                }
                bridge.urlHandlerTokens[id] = token
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("urlhandler.unregister", permission: "urlhandler", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let t = b.urlHandlerTokens.removeValue(forKey: id) else { return false }
                t.cancel()
                return true
            },
        ]
    }
}
