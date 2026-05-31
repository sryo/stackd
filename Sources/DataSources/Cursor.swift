import AppKit
import CoreGraphics

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
