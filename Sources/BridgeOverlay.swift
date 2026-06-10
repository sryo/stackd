import Foundation

/// Overlay primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1+A4). Four entries
/// covering the WebKit-overlay primitive:
///
///   - `overlay.attach` — async on main; creates a borderless click-
///     through NSPanel + WKWebView pinned to a foreign target window we
///     don't own. Subscribes to the shared `DisplayLinkObserver` so the
///     panel repositions per vsync to track `SLSGetWindowBounds`. The
///     stack supplies {html, css?, js?}; rendering is plain WebKit, the
///     daemon is observe + set only.
///
///   - `overlay.setTarget` — retarget an existing overlay at a new
///     window without tearing it down. Used by overlay-border to keep one
///     overlay across the session and just move/resize it on focus
///     change — the prior detach-then-attach cycle produced ghost borders
///     when detach didn't complete before the next attach ran.
///
///   - `overlay.eval` — evaluate arbitrary JS in the overlay's WebView.
///     Pairs with setTarget so the stack can update the overlay's
///     appearance (color, radius, theme) when retargeting. The overlay's
///     WebView is otherwise opaque to the host stack — no postMessage
///     channel.
///
///   - `overlay.detach` — cancel the displayLink subscription, then close
///     the overlay NSPanel synchronously. Detaching does NOT touch the
///     target window. Synchronous teardown (sync-hop to main if needed)
///     so the JS-side await doesn't resolve until the panel is actually
///     gone — a follow-up attach in the same turn would otherwise produce
///     two visible overlays.
///
/// `overlayHandles`, `overlayTokens`, `overlayInFlight` and
/// `nextOverlayId` were widened from fileprivate to internal in
/// Bridge.swift so this file's `.custom` / `.syncBridge` closures can mint
/// and release `OverlayHandle`s. Scope drain on stack unload cancels every
/// per-overlay displayLink subscription, then sync-hops to main to detach
/// each handle so a hot-reload doesn't strand the panels.
extension Bridge {
    /// Overlay primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func overlayPrimitives() -> [Primitive] {
        return [
            // ── Overlay (WebKit overlay primitive) ─────────────────────────────
            // Attach a borderless click-through NSPanel + WKWebView pinned to a
            // target window we don't own. The stack supplies {html, css?, js?};
            // per vsync we reposition the panel to SLSGetWindowBounds(targetWID)
            // and push `window.sd.target = {x,y,w,h}` into the overlay's WebView.
            // The daemon is observe + set only — no CGContext drawing, no spec
            // DSL. Rendering is plain WebKit. Permission: "overlay".
            .custom("overlay.attach", permission: "overlay") { bridge, body, requestId in
                DispatchQueue.main.async { [weak bridge] in
                    guard let bridge = bridge,
                          let wid = body["targetId"] as? Int else {
                        bridge?.respond(requestId: requestId, value: NSNull()); return
                    }
                    let html = body["html"] as? String ?? ""
                    let css  = body["css"]  as? String ?? ""
                    let js   = body["js"]   as? String ?? ""
                    let id = bridge.nextOverlayId
                    bridge.nextOverlayId += 1
                    guard let handle = Overlay.attach(
                        targetID: CGWindowID(wid), id: id,
                        html: html, css: css, js: js
                    ) else {
                        bridge.respond(requestId: requestId, value: NSNull()); return
                    }
                    bridge.overlayHandles[id] = handle

                    // Vsync tick → reposition + sd.target push. We subscribe to
                    // the shared DisplayLinkObserver (also drives sd.displayLink)
                    // so multiple overlays share one CVDisplayLink —
                    // RefCountedObserver handles install/teardown.
                    let token = DisplayLinkObserver.shared.subscribe { [weak bridge] in
                        guard let bridge = bridge,
                              let h = bridge.overlayHandles[id] else { return }
                        // Target gone or hidden (user closed / minimized /
                        // cmd-H'd the underlying window mid-overlay): hide
                        // the panel and bail. Without this, the panel stayed
                        // drawn at lastFrame after the target vanished — a
                        // ghost border floating in space. Show it again on
                        // the next tick where the target returns (e.g. user
                        // un-minimizes).
                        guard Overlay.isOrderedIn(h.targetWID),
                              let frame = Overlay.bounds(of: h.targetWID) else {
                            if h.panel.isVisible { h.panel.orderOut(nil) }
                            return
                        }
                        if !h.panel.isVisible {
                            h.panel.orderFrontRegardless()
                            // Coming back from the target-hidden branch: the
                            // target may have returned at its exact old frame
                            // (un-minimize restores geometry), so the frame
                            // diff alone would skip the SLS reorder and the
                            // panel could sit BELOW the freshly-restored
                            // target. Force the full repin path this tick.
                            h.forceRepin()
                        }
                        h.tick(targetFrame: frame)
                    }
                    bridge.overlayTokens[id] = token
                    bridge.respond(requestId: requestId, value: id)
                }
            },
            // Retarget an existing overlay at a new window without tearing it
            // down. Used by overlay-border to keep one overlay across the
            // session and just move/resize it on focus change — the prior
            // detach-then-attach cycle produced ghost borders when detach
            // didn't complete before the next attach ran.
            .syncBridge("overlay.setTarget", permission: "overlay", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let wid = body["targetId"] as? Int,
                      let handle = b.overlayHandles[id] else { return false }
                if Thread.isMainThread {
                    handle.setTarget(CGWindowID(wid))
                } else {
                    DispatchQueue.main.sync { handle.setTarget(CGWindowID(wid)) }
                }
                return true
            },
            // Evaluate arbitrary JS in the overlay's WebView. Pairs with
            // setTarget so the stack can update the overlay's appearance
            // (color, radius, theme) when retargeting. The overlay's WebView
            // is otherwise opaque to the host stack — no postMessage channel.
            .syncBridge("overlay.eval", permission: "overlay", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let js = body["js"] as? String,
                      let handle = b.overlayHandles[id] else { return false }
                if Thread.isMainThread {
                    handle.evaluate(js)
                } else {
                    DispatchQueue.main.sync { handle.evaluate(js) }
                }
                return true
            },
            // Tear down: cancel the displayLink subscription, then close the
            // overlay NSPanel. Detaching does NOT touch the target window.
            .syncBridge("overlay.detach", permission: "overlay", denyValue: false) { b, body in
                guard let id = body["id"] as? Int else { return false }
                if let token = b.overlayTokens.removeValue(forKey: id) { token.cancel() }
                if let handle = b.overlayHandles.removeValue(forKey: id) {
                    // Synchronous teardown — the JS-side await must not resolve
                    // until the NSPanel is actually gone. The old async path
                    // returned success while the panel was still onscreen, so
                    // a follow-up attach (focus change, hot-reload) produced
                    // two overlays visible at the same time. handle.detach is
                    // already main-thread-safe (it sync-hops if needed); we
                    // sync-hop here too rather than fire-and-forget.
                    if Thread.isMainThread {
                        handle.detach()
                    } else {
                        DispatchQueue.main.sync { handle.detach() }
                    }
                }
                b.overlayInFlight.remove(id)
                return true
            },
        ]
    }
}
