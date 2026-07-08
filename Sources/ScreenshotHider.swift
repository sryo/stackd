import AppKit

// Hide click-through panels while the macOS screenshot UI is active.
//
// The Cmd-Shift-4/5 window picker enumerates every on-screen window by
// level and highlights whatever is under the cursor — which, with
// always-on-top click-through overlays covering the screen, is the overlay,
// never the window beneath. No public API makes a window picker-invisible
// while staying on top: NSWindow.sharingType is ignored by the capture
// pipeline on macOS 15+, and lowering the window level breaks the
// always-on-top contract. So instead: while `com.apple.screencaptureui`
// is running, order out every visible click-through surface; restore when
// it exits. Trade-off (accepted): overlays don't appear in screenshots.
//
// Known limitations, by design for v1:
// - Cmd-Shift-5 screen recordings keep screencaptureui alive for the whole
//   recording, so overlays stay hidden until the recording stops.
// - Cmd-Shift-3 (instant capture) may spawn-and-exit faster than the hide
//   lands; harmless either way.
// - A stack spawned or hot-reloaded mid-session orders its new panel front
//   during the picker; it gets hidden on the next session.

/// Pure hide predicate — headlessly testable.
enum ScreenshotHidePolicy {
    static let bundleID = "com.apple.screencaptureui"

    static func isScreenshotApp(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == bundleID
    }

    /// Hide iff the window is a live click-through surface that hasn't
    /// opted out. `ignoresMouseEvents` is the semantic "click-through
    /// surface" test: the picker can't click-target these windows anyway —
    /// on screen they're pure occlusion. A currently-clickable panel (the
    /// bar mid-hover-flip) is a legitimate picker target and stays.
    static func shouldHide(isVisible: Bool, ignoresMouseEvents: Bool, optedOut: Bool) -> Bool {
        isVisible && ignoresMouseEvents && !optedOut
    }
}

/// Pure two-state machine — one hide and one restore per screenshot
/// session, no matter how many KVO callbacks land.
struct ScreenshotSession {
    enum State { case idle, hiding }
    private(set) var state: State = .idle

    mutating func screenshotUIAppeared() -> Bool {
        guard state == .idle else { return false }
        state = .hiding
        return true
    }

    mutating func screenshotUIExited() -> Bool {
        guard state == .hiding else { return false }
        state = .idle
        return true
    }
}

/// Impure watcher + orchestration. Installed once from AppDelegate.
final class ScreenshotHider {
    static let shared = ScreenshotHider()

    /// Read by BridgeOverlay's vsync tick: while true, the tick's
    /// "panel not visible → re-show + repin" branch must stay dormant or
    /// it would undo the hide one frame later.
    private(set) var active = false

    private var session = ScreenshotSession()
    /// Exactly the windows WE hid, for exact restore. Weak so a stack
    /// teardown mid-session can't keep dead panels alive.
    private var hidden = NSHashTable<NSWindow>.weakObjects()
    private var kvo: NSKeyValueObservation?

    var hiddenCount: Int { hidden.count }

    /// Detection is event-driven: KVO on `NSWorkspace.runningApplications`
    /// (documented KVO-compliant), diffed for the screencaptureui bundle id.
    /// screencaptureui is a launchd-spawned LSUIElement agent that is NOT
    /// resident at idle (verified macOS 26.5.1) — it appears on
    /// Cmd-Shift-4/5 and exits with the session, so presence maps 1:1 to
    /// "picker is up". KVO chosen over didLaunch/didTerminate notifications
    /// because those have historically been unreliable for UIElement agents;
    /// if KVO ever proves silent here, the fallback ladder is (1) the
    /// workspace notification pair, (2) a CGS session event discovered via
    /// STACKD_CGS_DEBUG=1, (3) a documented-ceiling poll. `.initial` covers
    /// a daemon (re)start landing mid-screenshot-session.
    func install() {
        kvo = NSWorkspace.shared.observe(\.runningApplications, options: [.initial, .new]) { [weak self] workspace, _ in
            let up = workspace.runningApplications.contains {
                ScreenshotHidePolicy.isScreenshotApp($0.bundleIdentifier)
            }
            DispatchQueue.main.async { self?.setActive(up) }
        }
    }

    /// Main thread only. Idempotent per direction via ScreenshotSession.
    func setActive(_ up: Bool) {
        if up {
            guard session.screenshotUIAppeared() else { return }
            active = true
            hideAll(NSApp.windows)
        } else {
            guard session.screenshotUIExited() else { return }
            active = false
            restoreAll()
        }
    }

    /// Enumerating NSApp.windows (injectable for tests) covers every
    /// StackWindow AND every overlay panel — window-pinned and region —
    /// without inventing another registry.
    func hideAll(_ windows: [NSWindow]) {
        for w in windows {
            let optedOut = (w as? StackWindow)?.hideDuringScreenshot == false
            guard ScreenshotHidePolicy.shouldHide(
                isVisible: w.isVisible,
                ignoresMouseEvents: w.ignoresMouseEvents,
                optedOut: optedOut
            ) else { continue }
            hidden.add(w)
            w.orderOut(nil)
        }
        log("screenshot UI active → hid \(hidden.count) click-through panel(s)")
    }

    private func restoreAll() {
        let count = hidden.count
        for w in hidden.allObjects {
            w.orderFrontRegardless()
        }
        hidden.removeAllObjects()
        // Overlay panels restored above bypass the vsync tick's re-show
        // branch (the one that forceRepin()s), so fan the repin out
        // explicitly — the border must re-assert z-order above its target.
        Overlay.repinAllAfterScreenshot()
        log("screenshot UI gone → restored \(count) panel(s)")
    }
}
