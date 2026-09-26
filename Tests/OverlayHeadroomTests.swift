import Foundation
import CoreGraphics

// Tests for `OverlayHeadroom` in `Sources/DataSources/Overlay.swift` — panel
// sizing during a user live resize. While the target is being resized the
// panel is rounded up with room to grow, so most resize ticks are cheap
// moves instead of WebKit reshapes; it is fitted exactly once the resize
// pauses. And `OverlayGeometry.panelFrame(target:outset:size:)`, which keeps
// the target at (outset, outset) from the panel's top-left whatever the
// panel size.

func registerOverlayHeadroomTests() {
    let content = CGSize(width: 416, height: 316)
    let step = OverlayHeadroom.step

    test("OverlayHeadroom: not resizing fits the panel exactly") {
        var h = OverlayHeadroom()
        try expect(h.panelSize(content: content, current: nil, resizing: false, now: 0) == content)
        try expect(h.panelSize(content: content, current: CGSize(width: 900, height: 900),
                               resizing: false, now: 0) == content)
    }

    test("OverlayHeadroom: resizing past the panel rounds up with room to grow") {
        var h = OverlayHeadroom()
        let s = h.panelSize(content: content, current: CGSize(width: 400, height: 300),
                            resizing: true, now: 0)
        try expect(s.width >= content.width * (1 + OverlayHeadroom.room))
        try expect(s.height >= content.height * (1 + OverlayHeadroom.room))
        try expectEqual(s.width.truncatingRemainder(dividingBy: step), 0)
        try expectEqual(s.height.truncatingRemainder(dividingBy: step), 0)
        try expect(s.width - content.width * (1 + OverlayHeadroom.room) < step, "rounded to the next step only")
    }

    test("OverlayHeadroom: room is capped at the desktop edge, never below the content") {
        var h = OverlayHeadroom()
        let capped = h.panelSize(content: content, current: nil, resizing: true, now: 0,
                                 limit: { CGSize(width: 500, height: 350) })
        try expect(capped == CGSize(width: 500, height: 350))
        var h2 = OverlayHeadroom()
        let tight = h2.panelSize(content: content, current: nil, resizing: true, now: 0,
                                 limit: { CGSize(width: 100, height: 100) })
        try expect(tight == content, "a target already past the edge still gets its full size")
    }

    test("OverlayHeadroom: the limit is only read when growing") {
        var h = OverlayHeadroom()
        var read = false
        _ = h.panelSize(content: content, current: nil, resizing: false, now: 0,
                        limit: { read = true; return nil })
        _ = h.panelSize(content: content, current: CGSize(width: 900, height: 900), resizing: true, now: 0,
                        limit: { read = true; return nil })
        try expect(!read)
    }

    test("OverlayHeadroom: resizing within the panel keeps its size (no reshape)") {
        var h = OverlayHeadroom()
        let big = CGSize(width: 768, height: 512)
        try expect(h.panelSize(content: content, current: big, resizing: true, now: 0) == big)
        let shrunk = CGSize(width: 300, height: 200)
        try expect(h.panelSize(content: shrunk, current: big, resizing: true, now: 0.016) == big)
    }

    test("OverlayHeadroom: holds the room through short pauses") {
        var h = OverlayHeadroom()
        let big = CGSize(width: 768, height: 512)
        _ = h.panelSize(content: content, current: big, resizing: true, now: 1)
        try expect(h.panelSize(content: content, current: big, resizing: false,
                               now: 1 + OverlayHeadroom.settle - 0.01) == big)
    }

    test("OverlayHeadroom: fits exactly once the resize has paused for the settle time") {
        var h = OverlayHeadroom()
        let big = CGSize(width: 768, height: 512)
        _ = h.panelSize(content: content, current: big, resizing: true, now: 1)
        try expect(h.panelSize(content: content, current: big, resizing: false,
                               now: 1 + OverlayHeadroom.settle + 0.01) == content)
    }

    test("OverlayHeadroom: settle time is a short pause, not a lingering oversize") {
        try expect(OverlayHeadroom.settle > LiveResizeDetector.quiet)
        try expect(OverlayHeadroom.settle <= 0.5)
    }

    test("OverlayGeometry.panelFrame with a size anchors the target at (outset, outset)") {
        let target = CGRect(x: 100, y: 50, width: 400, height: 300)
        let f = OverlayGeometry.panelFrame(target: target, outset: 8,
                                           size: CGSize(width: 768, height: 512))
        try expectEqual(f.origin.x, 92)
        try expectEqual(f.origin.y, 42)
        try expectEqual(f.width, 768)
        try expectEqual(f.height, 512)
    }

    test("OverlayGeometry.panelFrame with the exact size matches the outset frame") {
        let target = CGRect(x: 100, y: 50, width: 400, height: 300)
        let exact = OverlayGeometry.panelFrame(target: target, outset: 8)
        try expect(OverlayGeometry.panelFrame(target: target, outset: 8, size: exact.size) == exact)
    }
}
