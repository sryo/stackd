import AppKit
import CoreGraphics

/// Fires on every CGEvent mouse move. Replaces the 33 Hz `mouseTimer` poll
/// in Bridge — idle CPU drops to zero, active movement updates faster than
/// the old 30 Hz ceiling.
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
        return EventTapRegistry.shared.register(eventType: .mouseMoved) { [weak self] _ in
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
