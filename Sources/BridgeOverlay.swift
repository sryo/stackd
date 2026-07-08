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
                    // Scope already drained (stack unloaded/reloaded while this
                    // async create was queued): creating now orphans the panel,
                    // since the one-shot scope-drain teardown already passed.
                    guard !bridge.scope.isDrained else {
                        bridge.respond(requestId: requestId, value: NSNull()); return
                    }
                    let html = body["html"] as? String ?? ""
                    let css  = body["css"]  as? String ?? ""
                    let js   = body["js"]   as? String ?? ""
                    // Panel extends this many points beyond the target on
                    // every side (0 = legacy exact pin). Lets a border stack
                    // draw its ring AROUND the window instead of over it.
                    let outset = (body["outset"] as? NSNumber)?.doubleValue ?? 0
                    let id = bridge.nextOverlayId
                    bridge.nextOverlayId += 1
                    guard let handle = Overlay.attach(
                        targetID: CGWindowID(wid), id: id,
                        html: html, css: css, js: js,
                        outset: CGFloat(outset)
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
                        // Screenshot session in progress: ScreenshotHider
                        // ordered the panel out; the re-show branch below
                        // would undo that one frame later. Stay dormant —
                        // geometry resumes on session exit (the hider's
                        // restore + repinAllAfterScreenshot handles z-order).
                        if ScreenshotHider.shared.active { return }
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
            // Change the panel's outset without retargeting. The handle
            // forceRepin()s so the next vsync tick repositions even if the
            // target itself hasn't moved.
            .syncBridge("overlay.setOutset", permission: "overlay", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let n = (body["outset"] as? NSNumber)?.doubleValue,
                      let handle = b.overlayHandles[id] else { return false }
                if Thread.isMainThread {
                    handle.setOutset(CGFloat(n))
                } else {
                    DispatchQueue.main.sync { handle.setOutset(CGFloat(n)) }
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
                    // until the NSPanel is actually gone. If it resolved while
                    // the panel was still onscreen, a follow-up attach (focus
                    // change, hot-reload) would produce two overlays visible at
                    // the same time. handle.detach is
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
            // ── Free-region overlay ────────────────────────────────────────────
            // Like overlay.attach but positioned by an absolute GLOBAL rect
            // (top-left) instead of tracking a window. AppKit's global coord
            // space spans all displays, so the panel lands on whichever display
            // contains the rect — no per-vsync tick, no reorder. First consumer:
            // windowscape's 3-finger resize preview (its own panel is
            // display:"primary", so the preview couldn't show on other displays).
            .custom("overlay.region.create", permission: "overlay") { bridge, body, requestId in
                DispatchQueue.main.async { [weak bridge] in
                    guard let bridge = bridge,
                          let r = body["rect"] as? [String: Any],
                          let x = (r["x"] as? NSNumber)?.doubleValue,
                          let y = (r["y"] as? NSNumber)?.doubleValue,
                          let w = (r["w"] as? NSNumber)?.doubleValue,
                          let h = (r["h"] as? NSNumber)?.doubleValue else {
                        bridge?.respond(requestId: requestId, value: NSNull()); return
                    }
                    // Scope already drained (stack unloaded/reloaded while this
                    // async create was queued): creating now orphans the panel,
                    // since the one-shot scope-drain teardown already passed —
                    // this is the region-overlay (snapshot rail) leak fix.
                    guard !bridge.scope.isDrained else {
                        bridge.respond(requestId: requestId, value: NSNull()); return
                    }
                    let html = body["html"] as? String ?? ""
                    let css  = body["css"]  as? String ?? ""
                    let id = bridge.nextOverlayId
                    bridge.nextOverlayId += 1
                    guard let handle = Overlay.region(
                        id: id, rect: CGRect(x: x, y: y, width: w, height: h),
                        html: html, css: css
                    ) else {
                        bridge.respond(requestId: requestId, value: NSNull()); return
                    }
                    bridge.regionOverlayHandles[id] = handle
                    bridge.respond(requestId: requestId, value: id)
                }
            },
            // Re-place an existing region overlay at a new global rect.
            .syncBridge("overlay.region.setFrame", permission: "overlay", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let r = body["rect"] as? [String: Any],
                      let x = (r["x"] as? NSNumber)?.doubleValue,
                      let y = (r["y"] as? NSNumber)?.doubleValue,
                      let w = (r["w"] as? NSNumber)?.doubleValue,
                      let h = (r["h"] as? NSNumber)?.doubleValue,
                      let handle = b.regionOverlayHandles[id] else { return false }
                let rect = CGRect(x: x, y: y, width: w, height: h)
                if Thread.isMainThread { handle.setFrame(rect) }
                else { DispatchQueue.main.sync { handle.setFrame(rect) } }
                return true
            },
            // Evaluate JS in a region overlay's WebView (parity with overlay.eval).
            .syncBridge("overlay.region.eval", permission: "overlay", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let js = body["js"] as? String,
                      let handle = b.regionOverlayHandles[id] else { return false }
                if Thread.isMainThread { handle.evaluate(js) }
                else { DispatchQueue.main.sync { handle.evaluate(js) } }
                return true
            },
            // Daemon-side cursor follower. Per-mousemove JS RPCs (eventtap →
            // stack JS → region.setFrame) are two IPC hops with no coalescing
            // and lag progressively during a drag; instead the daemon moves
            // the panel itself per vsync tick: origin = Mouse.location() +
            // (dx, dy), size unchanged. Re-follow replaces the prior offsets
            // (last-write-wins). Subscription lifecycle mirrors overlay.attach:
            // one DisplayLinkObserver token per region id, cancelled by
            // unfollow / region.remove / scope drain.
            .syncBridge("overlay.region.follow", permission: "overlay", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      b.regionOverlayHandles[id] != nil else { return false }
                let dx = CGFloat((body["dx"] as? NSNumber)?.doubleValue ?? 0)
                let dy = CGFloat((body["dy"] as? NSNumber)?.doubleValue ?? 0)
                // Subscribe on main: DisplayLinkObserver primes the callback
                // synchronously at subscribe time, and the tick body touches
                // the NSPanel (setFrame) — same reason attach subscribes
                // inside its main-async block.
                let subscribe = {
                    b.regionFollowTokens.removeValue(forKey: id)?.cancel()
                    let offset = CGPoint(x: dx, y: dy)
                    var lastCursor: CGPoint?
                    let token = DisplayLinkObserver.shared.subscribe { [weak b] in
                        guard let b = b,
                              let h = b.regionOverlayHandles[id] else { return }
                        // Screenshot session: ScreenshotHider ordered the
                        // panel out; moving it would re-show it one frame
                        // later. Stay dormant (mirrors the attach tick).
                        if ScreenshotHider.shared.active { return }
                        let cursor = Mouse.location()
                        if cursor == lastCursor { return }
                        lastCursor = cursor
                        h.setFrame(RegionFollowGeometry.frame(
                            cursor: cursor, offset: offset,
                            size: h.panel.frame.size))
                    }
                    b.regionFollowTokens[id] = token
                }
                if Thread.isMainThread { subscribe() }
                else { DispatchQueue.main.sync { subscribe() } }
                return true
            },
            // Stop following. Double-unfollow (or unfollow without a live
            // follow) is a safe no-op that still resolves true — the desired
            // end state ("panel not following") already holds.
            .syncBridge("overlay.region.unfollow", permission: "overlay", denyValue: false) { b, body in
                guard let id = body["id"] as? Int else { return false }
                b.regionFollowTokens.removeValue(forKey: id)?.cancel()
                return true
            },
            // Tear down: cancel any live cursor follow, then close the panel
            // synchronously (sync-hop to main if needed).
            .syncBridge("overlay.region.remove", permission: "overlay", denyValue: false) { b, body in
                guard let id = body["id"] as? Int else { return false }
                b.regionFollowTokens.removeValue(forKey: id)?.cancel()
                guard let handle = b.regionOverlayHandles.removeValue(forKey: id) else { return false }
                if Thread.isMainThread { handle.remove() }
                else { DispatchQueue.main.sync { handle.remove() } }
                return true
            },
        ]
    }
}
