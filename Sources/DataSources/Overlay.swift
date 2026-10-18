import AppKit
import WebKit
import CoreGraphics

// WebKit overlay primitive: a borderless click-through NSPanel hosting a
// WKWebView, pinned to a target window we don't own. The stack supplies
// {html, css?, js?}; the daemon repositions the panel to match
// SLSGetWindowBounds(targetWID) — every vsync while window events say the
// target may be changing, on a slow backstop otherwise (OverlayTickArm) —
// and, when the target's size or the outset changes, pushes
// `window.sd.target = {x,y,w,h}` into the overlay's WebView. Rendering is WebKit; the daemon only observes and sets geometry.
//
// Why NSPanel + WKWebView instead of an SLS-owned sibling window (the
// JankyBorders pattern):
// - WebKit wants its own CALayer hosting tree; SLWindowContextCreate-bound
//   CGContexts don't compose with WKWebView's layers.
// - NSPanel already gives us borderless + transparent + click-through +
//   stays-across-spaces (canJoinAllSpaces + stationary + fullScreenAuxiliary
//   + ignoresCycle) — see StackWindow.swift for the same recipe.
// - We still use SLSTransactionOrderWindow to order the panel ABOVE the
//   target (a foreign-owned window) per tick, since NSWindow.level alone
//   only orders against other AppKit levels in our own connection.

// MARK: - Borderless transparent overlay panel

/// Borderless transparent NSPanel that hosts the overlay's WKWebView.
/// Distinct subclass (rather than reusing StackWindow) because the overlay
/// has different lifecycle needs: no sd:// scheme handler, no manifest
/// chrome, no invocable surface — just an HTML/CSS render canvas pinned
/// to a foreign window.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay (factory)

enum Overlay {
    /// Live handles, weakly held, for the CGS-808 reorder fan-out below.
    /// Main-thread only (attach runs on main via BridgeOverlay; 808 events
    /// hop to main in WindowEvents.handleModify). Weak table self-cleans
    /// when Bridge drops a handle; the `released` guard in forceRepin
    /// covers detached-but-not-yet-deallocated handles.
    private static let liveHandles = NSHashTable<OverlayHandle>.weakObjects()

    /// Track a handle for reorder-event fan-out. Called by attach();
    /// internal (not fileprivate) so tests can exercise
    /// notifyWindowReordered against degenerate handles.
    static func register(_ handle: OverlayHandle) {
        liveHandles.add(handle)
        installArmObservers()
        OverlayEventFollow.track(handle)
    }

    /// A window-server frame event for `wid` reached main: step every
    /// overlay tracking it now, and arm its tick as the backstop.
    static func followFrameEvent(wid: CGWindowID) {
        for handle in liveHandles.allObjects where handle.targetWID == wid {
            handle.followEvent()
        }
    }

    /// CGS 804 for `wid`. Main thread.
    static func noteTargetDestroyed(wid: CGWindowID) {
        OverlayEventFollow.dropTarget(wid: wid)
    }

    /// A motion-engine write of `frame` for `wid` landed: every overlay
    /// tracking it moves there now. Main thread only.
    static func followCommandedFrame(wid: CGWindowID, frame: CGRect) {
        for handle in liveHandles.allObjects where handle.targetWID == wid {
            handle.followCommanded(frame)
        }
    }

    /// The motion engine stopped animating `wid` (settled, cancelled or
    /// overridden by an instant write). Main thread only.
    static func endCommandedFrame(wid: CGWindowID) {
        for handle in liveHandles.allObjects where handle.targetWID == wid {
            handle.releaseCommanded()
        }
    }

    /// Something about window `wid` may be changing (AX move / resize,
    /// daemon frame write, minimize, …): arm the tick of every overlay
    /// tracking it. Main thread only.
    static func noteWindowActivity(wid: CGWindowID, hold: Double = OverlayTickArm.idle) {
        for handle in liveHandles.allObjects where handle.targetWID == wid {
            handle.arm(hold: hold)
        }
    }

    /// Host window-bang tap: every `sd.window.*` bang the host fans out to
    /// stacks also arms the overlays tracking that window.
    static func noteWindowBang(name: String, detail: [String: Any]) {
        guard let hold = OverlayArmEvents.hold(forBang: name) else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { noteWindowBang(name: name, detail: detail) }
            return
        }
        if let id = detail["id"] as? Int {
            noteWindowActivity(wid: CGWindowID(id), hold: hold)
        } else {
            armAll(hold: hold)
        }
    }

    static func armAll(hold: Double = OverlayTickArm.idle) {
        for handle in liveHandles.allObjects { handle.arm(hold: hold) }
    }

    private static var armObserversInstalled = false

    /// App hide / unhide, space switches and display changes can hide,
    /// show or move any target without a per-window event. Rare, so they
    /// arm every overlay rather than resolving which targets they touched.
    /// Installed once, on the first attach, for the process lifetime.
    private static func installArmObservers() {
        if armObserversInstalled { return }
        armObserversInstalled = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                armAll(hold: OverlayTickArm.visibilityHold)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            armAll(hold: OverlayTickArm.visibilityHold)
        }
    }

    /// CGS 808 ("window reordered") landed for `wid`. If any live overlay
    /// targets that window, its z-order may now be stale — the classic
    /// case is clicking the already-focused window, which raises it above
    /// the panel without changing its frame, so the frame-diff
    /// short-circuit in tick() would never reorder. Request a repin; the
    /// next vsync tick re-runs setFrame + SLSTransactionOrderWindow.
    static func notifyWindowReordered(wid: CGWindowID) {
        for handle in liveHandles.allObjects where handle.targetWID == wid {
            handle.forceRepin()
        }
    }

    /// After a screenshot session ends, ScreenshotHider re-shows every
    /// panel it hid — including overlay panels, whose direct
    /// orderFrontRegardless bypasses the vsync tick's re-show branch (the
    /// one that forceRepin()s). Fan the repin out explicitly so borders
    /// re-assert z-order above their targets on the next tick. Region
    /// overlays have no z-order tick; orderFront alone restores them.
    static func repinAllAfterScreenshot() {
        for handle in liveHandles.allObjects {
            handle.forceRepin()
        }
    }

    /// Take the panel off screen at the window server right now. AppKit's
    /// orderOut is only committed when the run loop turns, and a stack
    /// reload (display change) holds the main thread for seconds while
    /// every stack rebuilds — the old outline would sit frozen until then.
    /// AppKit's own orderOut still follows for its bookkeeping.
    static func orderOutNow(_ panel: NSPanel) {
        guard let create = WindowTransaction.create,
              let order  = WindowTransaction.orderWindow,
              let commit = WindowTransaction.commit else { return }
        let cid = SkyLight.cid
        guard cid != 0, panel.windowNumber > 0,
              let txRef = create(cid)?.takeRetainedValue() else { return }
        // Order 0 = out; the relative window is ignored.
        _ = order(txRef, UInt32(panel.windowNumber), 0, 0)
        commit(txRef, 0)
    }

    /// Move the panel at the window server in one transaction, optionally
    /// ordering it one slot above `above` in the same commit. No AppKit
    /// round-trip and no redisplay, so `panel.frame` keeps the old origin
    /// until the caller resyncs it. False when the SPI is unavailable or the
    /// panel has no window-server window yet; the caller falls back to
    /// setFrameOrigin.
    static func serverMove(_ panel: NSPanel, cgsOrigin: CGPoint, above: CGWindowID? = nil) -> Bool {
        guard panel.windowNumber > 0 else { return false }
        return serverMove(panelWID: UInt32(panel.windowNumber), cgsOrigin: cgsOrigin, above: above)
    }

    /// `serverMove` by window-server id, callable off main: it touches no
    /// AppKit state, only a transaction on the shared connection.
    static func serverMove(panelWID: UInt32, cgsOrigin: CGPoint, above: CGWindowID? = nil) -> Bool {
        guard let create = WindowTransaction.create,
              let move   = WindowTransaction.moveWithGroup,
              let order  = WindowTransaction.orderWindow,
              let commit = WindowTransaction.commit else { return false }
        let cid = SkyLight.cid
        guard cid != 0, panelWID != 0,
              let txRef = create(cid)?.takeRetainedValue() else { return false }
        _ = move(txRef, panelWID, cgsOrigin)
        if let above = above {
            _ = order(txRef, panelWID, 1, UInt32(above))
        }
        commit(txRef, 0)
        return true
    }

    /// Shared NSPanel recipe for attach() and region(): borderless,
    /// transparent, click-through, never key. `frame` is AppKit coordinates.
    /// `attachedToWindow` picks the space behavior: a panel pinned to a
    /// foreign window is transient so it steps aside with Show Desktop and
    /// Mission Control along with its target; a free region stays
    /// stationary like a HUD stack.
    static func makeOverlayPanel(frame: NSRect, attachedToWindow: Bool) -> NSPanel {
        let panel = OverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // An attached panel sits just under the Dock, above any normal
        // window it tracks (OverlayTargetLevel.panelLevel; the first tick
        // raises it for a target at or above that band). A free region
        // floats like a HUD stack.
        panel.level = attachedToWindow
            ? NSWindow.Level(rawValue: OverlayTargetLevel.panelLevel(above: NSWindow.Level.normal.rawValue))
            : .statusBar
        // Sticky across spaces, usable over full-screen apps, never in the
        // window cycle. Region panels add .stationary (StackWindow's recipe);
        // attached panels use .transient instead, which is mutually
        // exclusive with it.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
                                    attachedToWindow ? .transient : .stationary]
        panel.ignoresMouseEvents = true
        panel.unregisterDraggedTypes()
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        // Order-out must be immediate: an animated one needs the run loop,
        // and a stack reload (display change) blocks it for seconds while
        // every stack rebuilds — the old outline would sit frozen on screen.
        panel.animationBehavior = .none
        // Keeps the Cmd-Shift-4/5 window picker from offering the overlay
        // in place of the window beneath it. defer: false above means the
        // window-server window already exists.
        WindowServerProperty.setBool(WindowServerProperty.ignoreForScreencaptureSelection,
                                     true, on: CGWindowID(max(panel.windowNumber, 0)))
        return panel
    }

    /// Shared WKWebView recipe for overlay panels — attach() and region()
    /// build byte-identical webviews. Always drag-passthrough: every
    /// sd.overlay panel is ignoresMouseEvents=true by contract, and a
    /// drag-registered webview would make the invisible panel a Finder
    /// drag target (see PassthroughWebView).
    static func makeOverlayWebView(size: CGSize,
                                   userContent: WKUserContentController? = nil) -> PassthroughWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs
        if let userContent { config.userContentController = userContent }

        let webView = PassthroughWebView(
            frame: NSRect(origin: .zero, size: size),
            configuration: config,
            dragPassthrough: true
        )
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.isOpaque = false
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.underPageBackgroundColor = .clear
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.autoresizingMask = [.width, .height]
        return webView
    }
}
