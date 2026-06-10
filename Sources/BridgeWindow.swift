import WebKit

/// Self-panel window primitive group — extracted from Bridge.swift in the
/// A8 breakup round. These are the window.* entries that act on the stack's
/// OWN StackWindow (the panel hosting this Bridge's WKWebView), as opposed
/// to BridgeWindows.swift's windows.* primitives that act on OTHER apps'
/// windows via AX/SkyLight. All five hop to main for AppKit.
extension Bridge {
    /// Self-panel window primitives — concatenated into `Bridge.primitives`
    /// alongside the rest of the group builders. Pure builder; no side
    /// effects.
    static func windowPrimitives() -> [Primitive] {
        return [
            // Invocable-window control — async (must hop to main for AppKit).
            .custom("window.invoke", denyValue: false) { bridge, _, requestId in
                DispatchQueue.main.async { [weak bridge] in
                    if let win = bridge?.webView?.window as? StackWindow, win.invocable {
                        win.invoke()
                        bridge?.respond(requestId: requestId, value: true)
                    } else {
                        bridge?.respond(requestId: requestId, value: false)
                    }
                }
            },
            .custom("window.dismiss", denyValue: false) { bridge, _, requestId in
                DispatchQueue.main.async { [weak bridge] in
                    if let win = bridge?.webView?.window as? StackWindow, win.invocable {
                        win.dismiss()
                        bridge?.respond(requestId: requestId, value: true)
                    } else {
                        bridge?.respond(requestId: requestId, value: false)
                    }
                }
            },
            // JS-controlled window alpha. Not gated to invocable — any stack can
            // fade its panel (SideSwipe's volume/brightness disc, transient toasts,
            // anything that wants the whole window to fade rather than just the
            // WebView contents — CSS opacity on body doesn't reach the
            // NSGlassEffectView's glass layer).
            //
            // First call disables the FirstPaintGate's auto-reveal — see
            // StackWindow.setAlpha / FirstPaintGate.markOverridden.
            .custom("window.setAlpha", denyValue: false) { bridge, body, requestId in
                guard let alpha = StackWindow.parseSetAlpha(body) else {
                    bridge.respond(requestId: requestId, value: false)
                    return
                }
                DispatchQueue.main.async { [weak bridge] in
                    if let win = bridge?.webView?.window as? StackWindow {
                        win.setAlpha(alpha)
                        bridge?.respond(requestId: requestId, value: true)
                    } else {
                        bridge?.respond(requestId: requestId, value: false)
                    }
                }
            },
            // JS-controlled window frame. Input is in CG/AX convention (top-left
            // origin) — matches sd.windows.focused / sd.ax.attribute. Width / height
            // optional; omitted dimensions preserve current. Used by stacks that
            // reposition per-invocation (Muse anchors to AX-focused element) where
            // a single manifest anchor isn't expressive enough.
            .custom("window.setFrame", denyValue: false) { bridge, body, requestId in
                guard let f = StackWindow.parseSetFrame(body) else {
                    bridge.respond(requestId: requestId, value: false)
                    return
                }
                DispatchQueue.main.async { [weak bridge] in
                    if let win = bridge?.webView?.window as? StackWindow {
                        win.setFrame(cgX: f.x, cgY: f.y, w: f.w, h: f.h)
                        bridge?.respond(requestId: requestId, value: true)
                    } else {
                        bridge?.respond(requestId: requestId, value: false)
                    }
                }
            },
            // JS-controlled click-through. Bar-like stacks toggle this to route
            // events between themselves and the system menubar underneath as the
            // mouse moves over / off their item rects.
            .custom("window.setClickThrough", denyValue: false) { bridge, body, requestId in
                guard let v = StackWindow.parseSetClickThrough(body) else {
                    bridge.respond(requestId: requestId, value: false)
                    return
                }
                DispatchQueue.main.async { [weak bridge] in
                    if let win = bridge?.webView?.window as? StackWindow {
                        win.setClickThrough(v)
                        bridge?.respond(requestId: requestId, value: true)
                    } else {
                        bridge?.respond(requestId: requestId, value: false)
                    }
                }
            },
        ]
    }
}
