import AppKit
import CoreGraphics

// Manifest-driven hot corners. Each stack declares an array of
// { corner, callback, tooltip? } entries; the registry installs ONE
// mouseMoved tap that fans out enter/leave callbacks per entry.
//
// Reusing the existing CGEventTap for mouseMoved is intentional — installing
// a second global tap costs another Accessibility-gated CFMachPort and the
// fan-out logic here is cheaper than two taps' worth of context switches.
//
// "Touching" the corner means landing inside a 2 px band of the corner pixel
// of any active NSScreen — Hammerspoon's hot-corner behavior. Bigger bands
// (8-16 px) cause accidental fires when reaching for menu-bar items at
// (x, 0) on the top-left corner of the primary display.
//
// Consumer notes — FrameMaster-corners (primary): trigger window-layout
// presets by corner. Secondary: Mission Control / Exposé triggers that
// don't want to fight the system-level Mission Control prefs pane for the
// same corner (since hot-corners.app handlers won't fire if the user has
// the same corner bound there).

struct HotCornerSpec {
    enum Corner: String {
        case topLeft     = "top-left"
        case topRight    = "top-right"
        case bottomLeft  = "bottom-left"
        case bottomRight = "bottom-right"
    }
    let corner: Corner
    let callback: String
    let tooltip: String?
}

final class HotCornerWatcher {
    private let entries: [HotCornerSpec]
    private let fire: (HotCornerSpec, Bool, CGPoint) -> Void
    private var inside: [Int: Bool] = [:]    // entry-index → currently-inside
    // Width of the corner trigger band in points. Sub-pixel-ish so the cursor
    // must actually touch the corner (matches Hammerspoon).
    private static let band: CGFloat = 2.0

    init(entries: [HotCornerSpec], fire: @escaping (HotCornerSpec, Bool, CGPoint) -> Void) {
        self.entries = entries
        self.fire = fire
    }

    /// Call from a mouseMoved CGEvent handler. `loc` is the event's
    /// `event.location` (top-left global, matching every other sd.* xy).
    func tick(loc: CGPoint) {
        // CG global space: NSScreen.screens[0] is at (0,0). Other screens'
        // CGDisplayBounds carry their offset. NSScreen.frame is AppKit
        // bottom-left; we want CG top-left, so derive from CGDisplayBounds.
        for (i, e) in entries.enumerated() {
            let isIn = corner(matches: e.corner, point: loc)
            let was = inside[i] ?? false
            if isIn != was {
                inside[i] = isIn
                fire(e, isIn, loc)
            }
        }
    }

    private func corner(matches corner: HotCornerSpec.Corner, point: CGPoint) -> Bool {
        // Iterate every connected display — the active corner is "any corner
        // of any screen" so multi-monitor setups behave the way users expect
        // (top-left of the secondary fires top-left, not the primary's).
        for screen in NSScreen.screens {
            guard let cgID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let b = CGDisplayBounds(cgID)
            let band = HotCornerWatcher.band
            switch corner {
            case .topLeft:
                if point.x >= b.minX && point.x <= b.minX + band &&
                   point.y >= b.minY && point.y <= b.minY + band { return true }
            case .topRight:
                if point.x <= b.maxX - 1 && point.x >= b.maxX - 1 - band &&
                   point.y >= b.minY     && point.y <= b.minY + band { return true }
            case .bottomLeft:
                if point.x >= b.minX     && point.x <= b.minX + band &&
                   point.y <= b.maxY - 1 && point.y >= b.maxY - 1 - band { return true }
            case .bottomRight:
                if point.x <= b.maxX - 1 && point.x >= b.maxX - 1 - band &&
                   point.y <= b.maxY - 1 && point.y >= b.maxY - 1 - band { return true }
            }
        }
        return false
    }
}
