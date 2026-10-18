import ApplicationServices
import CoreGraphics
import Foundation

// Tests for `WindowAXRead` and `WindowSubroleVerdict` in
// `Sources/DataSources/Windows.swift`: several window attributes read in one
// AXUIElementCopyMultipleAttributeValues round trip. The decode of a result
// array is pure, so the per-slot AXError sentinel, kCFNull and whole-call
// failure paths run without Accessibility trust. The live read is exercised
// only against an element for a pid that cannot exist.

private let unreachablePid: pid_t = 0x7ffffffe

/// The AXValue CopyMultipleAttributeValues puts in a slot it could not read.
private func axErrorSlot(_ error: AXError) -> AnyObject {
    var raw = error.rawValue
    return AXValueCreate(.axError, &raw)!
}

private func axValue(point: CGPoint) -> AnyObject {
    var p = point
    return AXValueCreate(.cgPoint, &p)!
}

private func axValue(size: CGSize) -> AnyObject {
    var s = size
    return AXValueCreate(.cgSize, &s)!
}

private let subrole = kAXSubroleAttribute as String
private let minimized = kAXMinimizedAttribute as String
private let position = kAXPositionAttribute as String
private let size = kAXSizeAttribute as String

func registerWindowAXReadTests() {
    test("WindowAXRead: an AXError slot fails with its own error while the other slots keep their values") {
        let read = WindowAXRead(attributes: [minimized, subrole],
                                values: [axErrorSlot(.cannotComplete), "AXStandardWindow" as NSString],
                                callError: .success)
        try expect(read.value(minimized) == nil, "an AXError sentinel is not a value")
        try expectEqual(read.error(minimized), .cannotComplete)
        try expectEqual(read.string(subrole), "AXStandardWindow")
        try expectEqual(read.error(subrole), .success)
    }

    test("WindowSubroleVerdict keeps standard, non-standard and unknown apart when the subrole slot is an AXError") {
        func verdict(_ slot: AnyObject) -> WindowSubroleVerdict {
            WindowSubroleVerdict(WindowAXRead(attributes: [subrole], values: [slot], callError: .success)
                .slot(subrole))
        }
        try expectEqual(verdict("AXStandardWindow" as NSString), .standard)
        try expectEqual(verdict("AXDialog" as NSString), .nonStandard)
        // An errored read is "not known yet", never "definitely not a window":
        // the AX create gate rechecks unknowns instead of dropping them.
        try expectEqual(verdict(axErrorSlot(.cannotComplete)), .unknown)
        try expectEqual(verdict(axErrorSlot(.attributeUnsupported)), .unknown)
        try expectEqual(verdict(NSNumber(value: 1)), .unknown, "a non-string subrole is unreadable")
        let failed = WindowAXRead(attributes: [subrole], values: nil, callError: .cannotComplete)
        try expectEqual(WindowSubroleVerdict(failed.slot(subrole)), .unknown)
    }

    test("WindowAXRead: a call that fails outright fails every slot with the call's error") {
        let read = WindowAXRead(attributes: [minimized, subrole], values: nil, callError: .invalidUIElement)
        try expectEqual(read.error(minimized), .invalidUIElement)
        try expectEqual(read.error(subrole), .invalidUIElement)
        try expect(read.bool(minimized) == nil)
        try expect(read.string(subrole) == nil)
    }

    test("WindowAXRead: a null slot reads as no value, a missing slot as a failure") {
        let read = WindowAXRead(attributes: [subrole, minimized, position],
                                values: [kCFNull, NSNumber(value: true)],
                                callError: .success)
        try expectEqual(read.error(subrole), .noValue)
        try expect(read.value(subrole) == nil)
        try expectEqual(read.bool(minimized), true)
        try expect(read.value(position) == nil, "a slot past the returned array has no value")
        try expect(read.error(position) != .success)
    }

    test("WindowAXRead.frame needs both position and size") {
        let both = WindowAXRead(attributes: [position, size],
                                values: [axValue(point: CGPoint(x: 10, y: 20)),
                                         axValue(size: CGSize(width: 300, height: 200))],
                                callError: .success)
        try expectEqual(both.frame, CGRect(x: 10, y: 20, width: 300, height: 200))
        let noSize = WindowAXRead(attributes: [position, size],
                                  values: [axValue(point: CGPoint(x: 10, y: 20)), axErrorSlot(.cannotComplete)],
                                  callError: .success)
        try expect(noSize.frame == nil, "a frame without its size is no frame")
        try expectEqual(noSize.point(position), CGPoint(x: 10, y: 20), "the position slot still reads")
        let swapped = WindowAXRead(attributes: [position, size],
                                   values: [axValue(size: CGSize(width: 1, height: 1)),
                                            axValue(point: .zero)],
                                   callError: .success)
        try expect(swapped.frame == nil, "a size in the position slot is not a position")
    }

    test("WindowAXRead.frameOrZero keeps the half that read and zeroes the other") {
        let noSize = WindowAXRead(attributes: [position, size],
                                  values: [axValue(point: CGPoint(x: 10, y: 20)), axErrorSlot(.cannotComplete)],
                                  callError: .success)
        try expectEqual(noSize.frameOrZero, CGRect(x: 10, y: 20, width: 0, height: 0))
        let failed = WindowAXRead(attributes: [position, size], values: nil, callError: .cannotComplete)
        try expectEqual(failed.frameOrZero, .zero)
    }

    test("WindowAXRead.frame(of:) is nil for an element that cannot be read") {
        try expect(WindowAXRead.frame(of: AX.appElement(pid: unreachablePid, timeout: 0.05)) == nil)
    }

    test("WindowMotionEngine.animate completes unsettled when the window has no readable frame") {
        var settled: Bool?
        WindowMotionEngine.shared.animate(windowID: 0, to: CGRect(x: 0, y: 0, width: 100, height: 100),
                                          duration: 0.2, easing: .linear) { settled = $0 }
        try expectEqual(settled, false, "no element, no from-frame: nothing animates")
        try expect(!WindowMotionEngine.shared.isAnimating(windowID: 0))
    }

    test("WindowsByID frame write steps leave an unreadable element untouched") {
        // The lift and keep-inside steps read the current frame first; with
        // no frame to read they write nothing and must not trap.
        let el = AX.appElement(pid: unreachablePid, timeout: 0.05)
        WindowsByID.liftIfOverhanging(element: el, target: CGRect(x: 0, y: 0, width: 100, height: 100))
        WindowsByID.keepInsideIfHeldLarger(element: el, target: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    test("WindowAXRead of an unreachable element fails every slot and never traps") {
        let el = AX.appElement(pid: unreachablePid, timeout: 0.05)
        let read = WindowAXRead(el, [minimized, subrole, position, size])
        try expect(read.value(minimized) == nil)
        try expect(read.error(subrole) != .success)
        try expect(read.frame == nil)
        try expectEqual(WindowSubroleVerdict(read.slot(subrole)), .unknown)
    }
}
