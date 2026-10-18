import WebKit

/// Self-panel window primitive group. These are the window.* entries that act
/// on the stack's OWN StackWindow (the panel hosting this Bridge's WKWebView),
/// as opposed to BridgeWindows.swift's windows.* primitives that act on OTHER
/// apps' windows via AX/SkyLight. All of them hop to main for AppKit.
extension Bridge {
    /// Self-panel window primitives — concatenated into `Bridge.primitives`
    /// alongside the rest of the group builders. Pure builder; no side
    /// effects.
    static func windowPrimitives() -> [Primitive] {
        return [
            // Invocable-window control.
            selfPanel("window.invoke", parse: { _ in () }) { win, _ in
                guard win.invocable else { return false }
                win.invoke()
                return true
            },
            selfPanel("window.dismiss", parse: { _ in () }) { win, _ in
                guard win.invocable else { return false }
                win.dismiss()
                return true
            },
            // JS-controlled window alpha. Not gated to invocable — any stack can
            // fade its panel (SideSwipe's volume/brightness disc, transient toasts,
            // anything that wants the whole window to fade rather than just the
            // WebView contents — CSS opacity on body doesn't reach the
            // NSGlassEffectView's glass layer).
            //
            // First call disables the FirstPaintGate's auto-reveal — see
            // StackWindow.setAlpha / FirstPaintGate.markOverridden.
            selfPanel("window.setAlpha", parse: StackWindow.parseSetAlpha) { win, alpha in
                win.setAlpha(alpha)
                return true
            },
            // JS-controlled window frame. Input is in CG/AX convention (top-left
            // origin) — matches sd.windows.focused / sd.ax.attribute. Width / height
            // optional; omitted dimensions preserve current. Used by stacks that
            // reposition per-invocation (Muse anchors to AX-focused element) where
            // a single manifest anchor isn't expressive enough.
            selfPanel("window.setFrame", parse: StackWindow.parseSetFrame) { win, f in
                win.setFrame(cgX: f.x, cgY: f.y, w: f.w, h: f.h)
                return true
            },
            // sd-on:click backing. JS pushes the current set of interactive
            // element rects (CSS viewport coords, re-pushed on DOM/layout/
            // panel-frame changes); the daemon converts to global CG, gates a
            // daemon-internal mouseMoved observer on them, and flips the
            // panel's click-through as the pointer enters/leaves. The stack's
            // JS never receives the mouse events — this is not an input
            // permission surface, so like every window.* self-panel
            // primitive it is permissionless.
            .custom("window.setInteractiveRects", denyValue: false) { bridge, body, requestId in
                guard let parsed = StackWindow.parseInteractiveRects(body) else {
                    bridge.respond(requestId: requestId, value: false)
                    return
                }
                DispatchQueue.main.async { [weak bridge] in
                    guard let bridge = bridge,
                          let win = bridge.webView?.window as? StackWindow else {
                        bridge?.respond(requestId: requestId, value: false)
                        return
                    }
                    guard win.createdClickThrough else {
                        // Panel already receives clicks — nothing to gate.
                        bridge.respond(requestId: requestId, value: true)
                        return
                    }
                    let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
                    let global = StackWindow.screenRects(
                        viewport: parsed, panelFrame: win.frame, primaryMaxY: primaryMaxY)
                    let key = StackWindow.interactiveRectsKey(stackId: bridge.stackId, owner: bridge)
                    if !bridge.interactiveHoverInstalled {
                        bridge.interactiveHoverInstalled = true
                        // Empty gate first so the observer can't fire before
                        // rects land (same requireRects boot pattern as
                        // manifest eventtaps).
                        EventTapRegistry.shared.setConsumerRects(key: key, rects: [])
                        bridge.scope.adopt(EventTapRegistry.shared.register(
                            eventType: .mouseMoved, key: key, emitLeave: true
                        ) { [weak win] _, phase in
                            guard let win = win, let phase = phase else { return }
                            if phase == "enter" {
                                DispatchQueue.main.async { win.setClickThrough(false) }
                            } else if phase == "leave" {
                                DispatchQueue.main.async { win.setClickThrough(true) }
                            }
                        })
                    }
                    EventTapRegistry.shared.setConsumerRects(key: key, rects: global)
                    bridge.respond(requestId: requestId, value: true)
                }
            },
            // JS-controlled click-through. Bar-like stacks toggle this to route
            // events between themselves and the system menubar underneath as the
            // mouse moves over / off their item rects.
            selfPanel("window.setClickThrough", parse: StackWindow.parseSetClickThrough) { win, v in
                win.setClickThrough(v)
                return true
            },
        ]
    }

    /// A window.* primitive acting on the stack's own panel: a request
    /// `parse` rejects answers false at once; otherwise, on main, `act` runs
    /// against the StackWindow hosting the page and its result is the
    /// answer — false when the page isn't in a StackWindow.
    private static func selfPanel<Arg>(_ type: String,
                                       parse: @escaping ([String: Any]) -> Arg?,
                                       _ act: @escaping (StackWindow, Arg) -> Bool) -> Primitive {
        .custom(type, denyValue: false) { bridge, body, requestId in
            guard let arg = parse(body) else {
                bridge.respond(requestId: requestId, value: false)
                return
            }
            DispatchQueue.main.async { [weak bridge] in
                guard let bridge = bridge else { return }
                guard let win = bridge.webView?.window as? StackWindow else {
                    bridge.respond(requestId: requestId, value: false)
                    return
                }
                bridge.respond(requestId: requestId, value: act(win, arg))
            }
        }
    }
}
