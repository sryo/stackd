import Foundation
import ApplicationServices

// Tests for the shared AX attribute readers in AX.swift. The `from:` coercions
// are pure (an attribute value in, a typed value or nil out), so the wrong-type
// and missing-value paths run without Accessibility trust. The `of:` readers
// are exercised against an element for a pid that cannot exist, which every AX
// configuration answers with an error — the nil path the walkers rely on.

private let unreachablePid: pid_t = 0x7ffffffe

private func axValue(point: CGPoint) -> AnyObject {
    var p = point
    return AXValueCreate(.cgPoint, &p)!
}

private func axValue(size: CGSize) -> AnyObject {
    var s = size
    return AXValueCreate(.cgSize, &s)!
}

private func axValue(range: CFRange) -> AnyObject {
    var r = range
    return AXValueCreate(.cfRange, &r)!
}

func registerAXAttributeReadTests() {
    test("AX.string(from:) passes strings and rejects every other type") {
        try expectEqual(AX.string(from: "AXButton" as NSString), "AXButton")
        try expectEqual(AX.string(from: NSNumber(value: 1)), nil)
        try expectEqual(AX.string(from: nil), nil)
    }

    test("AX.bool(from:) reads numbers and rejects other types") {
        try expectEqual(AX.bool(from: NSNumber(value: true)), true)
        try expectEqual(AX.bool(from: NSNumber(value: false)), false)
        try expectEqual(AX.bool(from: "yes" as NSString), nil)
        try expectEqual(AX.bool(from: nil), nil)
    }

    test("AX.int(from:) reads numbers and rejects other types") {
        try expectEqual(AX.int(from: NSNumber(value: 12)), 12)
        try expectEqual(AX.int(from: "12" as NSString), nil)
        try expectEqual(AX.int(from: nil), nil)
    }

    test("AX.element(from:) accepts an AXUIElement and rejects other CF and Foundation types") {
        let app = AXUIElementCreateApplication(getpid())
        try expect(AX.element(from: app) != nil, "an AXUIElement is an element")
        try expect(AX.element(from: "x" as NSString) == nil, "a string is not an element")
        try expect(AX.element(from: axValue(point: .zero)) == nil, "an AXValue is not an element")
        try expect(AX.element(from: nil) == nil)
    }

    test("AX.elements(from:) accepts element arrays and rejects everything else") {
        let app = AXUIElementCreateApplication(getpid())
        try expectEqual(AX.elements(from: [app] as NSArray)?.count, 1)
        try expectEqual(AX.elements(from: [AXUIElement]() as NSArray)?.count, 0)
        try expect(AX.elements(from: "x" as NSString) == nil)
        try expect(AX.elements(from: nil) == nil)
    }

    test("AX point/size/range coercions read matching AXValues and reject mismatches") {
        let point = axValue(point: CGPoint(x: 3, y: 4))
        let size  = axValue(size: CGSize(width: 5, height: 6))
        let range = axValue(range: CFRange(location: 7, length: 8))

        try expectEqual(AX.point(from: point), CGPoint(x: 3, y: 4))
        try expectEqual(AX.size(from: size), CGSize(width: 5, height: 6))
        let r = AX.range(from: range)
        try expectEqual(r?.location, 7)
        try expectEqual(r?.length, 8)

        try expect(AX.point(from: size) == nil, "a size is not a point")
        try expect(AX.size(from: range) == nil, "a range is not a size")
        try expect(AX.range(from: point) == nil, "a point is not a range")
        try expect(AX.point(from: "x" as NSString) == nil, "a non-AXValue is not a point")
        try expect(AX.size(from: nil) == nil)
        try expect(AX.range(from: nil) == nil)
    }

    test("AX.appElement(pid:timeout:) targets the requested process") {
        let el = AX.appElement(pid: getpid(), timeout: 0.1)
        var pid: pid_t = 0
        try expectEqual(AXUIElementGetPid(el, &pid), .success)
        try expectEqual(pid, getpid())
    }

    test("AX readers return nil, never trap, when the element cannot be read") {
        let el = AX.appElement(pid: unreachablePid, timeout: 0.05)
        try expect(AX.value(of: el, kAXRoleAttribute) == nil)
        try expect(AX.string(of: el, kAXTitleAttribute) == nil)
        try expect(AX.bool(of: el, kAXEnabledAttribute) == nil)
        try expect(AX.int(of: el, kAXMenuItemCmdModifiersAttribute) == nil)
        try expect(AX.element(of: el, kAXFocusedWindowAttribute, timeout: 0.1) == nil)
        try expect(AX.elements(of: el, kAXChildrenAttribute, timeout: 0.1) == nil)
        try expect(AX.point(of: el, kAXPositionAttribute) == nil)
        try expect(AX.size(of: el, kAXSizeAttribute) == nil)
        try expect(AX.range(of: el, kAXSelectedTextRangeAttribute) == nil)
        try expect(!AX.hasValue(el, kAXMenuItemMarkCharAttribute))
    }
}
