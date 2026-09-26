import AppKit
import Foundation

/// Tests for `StackHost.menubarHeight(frame:visibleFrame:)`. The height is
/// the TOP inset of visibleFrame only: the dock's bottom or side inset must
/// never leak in, or a menubar-anchored bar lands dock-height below the
/// real menubar.
func registerMenubarFrameTests() {
    test("menubarHeight: notched primary (39pt top inset, 60pt bottom dock) = 39") {
        // Top inset = full.maxY - visible.maxY = 39.
        // Bottom inset = visible.minY - full.minY = 60 (dock).
        // A total-height difference (full.height - visible.height) would be 99.
        let full = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 60, width: 1512, height: 982 - 39 - 60)
        try expectEqual(StackHost.menubarHeight(frame: full, visibleFrame: visible), 39)
    }

    test("menubarHeight: external + bottom dock on this display = top inset only (24, NOT 24+dock)") {
        // visibleFrame loses BOTH top (menubar) and bottom (dock) inset on a
        // display with a non-zero origin; only the menubar counts.
        let full = NSRect(x: 1512, y: 100, width: 2560, height: 1440)
        let dockHeight: CGFloat = 80
        let visible = NSRect(x: 1512, y: 100 + dockHeight, width: 2560, height: 1440 - 24 - dockHeight)
        try expectEqual(StackHost.menubarHeight(frame: full, visibleFrame: visible), 24)
    }

    test("menubarHeight: external with separate-Spaces off (no menubar) = 0") {
        // visible.maxY == full.maxY → top inset is 0. Preserved fallback —
        // bar with size.h=0 ends up with height 0 (existing contract).
        let full = NSRect(x: 1512, y: 100, width: 2560, height: 1440)
        let visible = NSRect(x: 1512, y: 100, width: 2560, height: 1440)
        try expectEqual(StackHost.menubarHeight(frame: full, visibleFrame: visible), 0)
    }

    test("menubarHeight: dock on the left, no menubar on this display = 0 (side inset doesn't leak in)") {
        // visible loses width on the left; height equals frame height.
        // Regression guard: the helper only looks at vertical insets at the
        // TOP of the frame, side insets are out of scope.
        let full = NSRect(x: 0, y: 0, width: 1512, height: 1080)
        let visible = NSRect(x: 80, y: 0, width: 1512 - 80, height: 1080)
        try expectEqual(StackHost.menubarHeight(frame: full, visibleFrame: visible), 0)
    }
}
