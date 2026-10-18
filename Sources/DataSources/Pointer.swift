import AppKit
import Foundation

// MARK: ============================================================
// MARK: Mouse — pointer location + warp (read side)
// MARK: ============================================================

/// Fires on every CGEvent mouse move — event-driven, not polled, so idle
/// CPU is zero and active movement updates at the event rate rather than a
/// fixed poll ceiling.
///
/// Lazy: the CGEventTap handler is installed on first subscribe and removed
/// when the last unsubscribes (after the 5s debounce). The shared eventtap
/// itself stays — uninstalling it would force re-prompting for Accessibility.
final class MouseObserver: RefCountedObserver {
    static let shared = MouseObserver()
    private override init() { super.init() }

    override func install() -> Token? {
        // Returns nil when EventTapRegistry can't install (Accessibility
        // denied). The base class will retry on the next subscribe — so a
        // stack that's already subscribed when the user grants Accessibility
        // wakes up the moment the next signal subscribe arrives (or just
        // toggles itself off+on).
        return EventTapRegistry.shared.register(eventType: .mouseMoved) { [weak self] _, _ in
            self?.fire()
        }
    }
}

enum Mouse {
    // Cached primary screen height (for AppKit→CG Y-flip). Invalidates on screen change.
    private static var cachedPrimaryHeight: CGFloat?
    private static var screenChangeObserver: NSObjectProtocol? = {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in cachedPrimaryHeight = nil }
    }()

    static func isLeftButtonDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    static func location() -> CGPoint {
        _ = screenChangeObserver
        let appkit = NSEvent.mouseLocation
        if cachedPrimaryHeight == nil {
            cachedPrimaryHeight = NSScreen.screens.first?.frame.size.height
        }
        guard let h = cachedPrimaryHeight else { return appkit }
        return CGPoint(x: appkit.x, y: h - appkit.y)
    }

    /// Move the cursor without clicking (CGWarpMouseCursorPosition). The
    /// missing primitive next to sd.events.click — a stack composing
    /// behaviors like mouse-follows-focus or radial gesture menus needs to
    /// move the cursor independently of a click.
    ///
    /// Coordinates are top-left origin (the same space CGWindowList /
    /// sd.windows.focused().frame report), matching every other geometry
    /// surface stackd exposes.
    @discardableResult
    static func warp(x: Double, y: Double) -> Bool {
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        // Re-associate cursor with input after a warp — macOS otherwise
        // applies a ~250ms suppression window where trackpad/mouse motion
        // doesn't move the cursor.
        CGAssociateMouseAndMouseCursorPosition(1)
        return true
    }
}

// MARK: ============================================================
// MARK: Cursor — write-side warp with display-local coords
// MARK: ============================================================

// Write-side counterpart to sd.mouse: warp the cursor. CGWarpMouseCursorPosition
// takes top-left global screen coordinates, same convention every other sd.*
// xy field uses (Mouse.location flips NSEvent.mouseLocation for the same
// reason). No event is synthesized — consumers that need a synthetic move
// for hit-testing should follow with sd.events.click at the same point.
//
// Consumers — EdgeHopper: wrap the cursor to the opposite edge of the focused
// display once the user "punches through". CloudPad: replaces the JXA
// CGWarpMouseCursorPosition shim under the pointer-mode continuous-move path
// (one Apple Event per move becomes one in-process CG call).

enum Cursor {
    /// `display` is an optional CGDirectDisplayID; if provided, (x, y) are
    /// interpreted as display-local point coordinates. Otherwise they're
    /// global (top-left of the primary screen = 0, 0).
    @discardableResult
    static func setPosition(x: Double, y: Double, display: CGDirectDisplayID?) -> Bool {
        var gx = CGFloat(x)
        var gy = CGFloat(y)
        if let id = display {
            let b = CGDisplayBounds(id)
            gx += b.origin.x
            gy += b.origin.y
        }
        let err = CGWarpMouseCursorPosition(CGPoint(x: gx, y: gy))
        // Re-associate the mouse to the new cursor position. Without this,
        // there's a ~250ms window where hardware moves are blended into the
        // warp target — visible as a "snap, then drift" under rapid warps.
        CGAssociateMouseAndMouseCursorPosition(1)
        return err == .success
    }

    /// Top-left global coords, same shape as the `mouse` channel.
    static func position() -> [String: Int] {
        let p = Mouse.location()
        return ["x": Int(p.x), "y": Int(p.y)]
    }
}
