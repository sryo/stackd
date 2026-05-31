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

    override func install() -> Token {
        return EventTapRegistry.shared.register(eventType: .mouseMoved) { [weak self] _ in
            self?.fire()
        } ?? Token { }
        // ?? Token { } : AX denied → register returned nil → observer stays
        // dormant. Subscribers still get the immediate primer fire from the
        // base class but no subsequent mouse events.
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
}
