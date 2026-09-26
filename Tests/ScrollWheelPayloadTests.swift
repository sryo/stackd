import Foundation
import CoreGraphics

// Tests for `ScrollWheel` in Sources/DataSources/Input.swift — the scroll
// fields merged into a scrollWheel eventtap payload. CGEvents built with
// CGEvent(scrollWheelEvent2Source:) are never posted, so reading them is
// side-effect free.
func registerScrollWheelPayloadTests() {

    func makeScroll(dy: Int32, dx: Int32, units: CGScrollEventUnit = .pixel) -> CGEvent {
        CGEvent(scrollWheelEvent2Source: nil, units: units,
                wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
    }

    test("ScrollWheel.payload: maps axis 1 to Y and axis 2 to X") {
        let f = ScrollWheel.Fields(
            pointDeltaX: 3, pointDeltaY: -7,
            fixedDeltaX: 0.25, fixedDeltaY: -1.5,
            phase: 0, momentumPhase: 0, isContinuous: true, senderId: 0)
        let p = ScrollWheel.payload(f)
        try expectEqual(p["deltaX"] as? Double, 3)
        try expectEqual(p["deltaY"] as? Double, -7)
        try expectEqual(p["fixedDeltaX"] as? Double, 0.25)
        try expectEqual(p["fixedDeltaY"] as? Double, -1.5)
        try expectEqual(p["isContinuous"] as? Bool, true)
    }

    test("ScrollWheel.payload: names every scroll phase with NSEvent wording") {
        let cases: [(Int64, String)] = [
            (0, "none"), (1, "began"), (2, "changed"), (4, "ended"),
            (8, "cancelled"), (128, "mayBegin"), (64, "unknown")
        ]
        for (raw, name) in cases {
            let f = ScrollWheel.Fields(pointDeltaX: 0, pointDeltaY: 0, fixedDeltaX: 0, fixedDeltaY: 0,
                                       phase: raw, momentumPhase: 0, isContinuous: true, senderId: 0)
            try expectEqual(ScrollWheel.payload(f)["scrollPhase"] as? String, name, "phase \(raw)")
        }
    }

    test("ScrollWheel.payload: names momentum phases began/changed/ended") {
        let cases: [(Int64, String)] = [(0, "none"), (1, "began"), (2, "changed"), (3, "ended"), (9, "unknown")]
        for (raw, name) in cases {
            let f = ScrollWheel.Fields(pointDeltaX: 0, pointDeltaY: 0, fixedDeltaX: 0, fixedDeltaY: 0,
                                       phase: 0, momentumPhase: raw, isContinuous: true, senderId: 0)
            try expectEqual(ScrollWheel.payload(f)["momentumPhase"] as? String, name, "momentum \(raw)")
        }
    }

    test("ScrollWheel.payload: unknown sender is null, a known one is a number") {
        let unknown = ScrollWheel.Fields(pointDeltaX: 0, pointDeltaY: 0, fixedDeltaX: 0, fixedDeltaY: 0,
                                         phase: 0, momentumPhase: 0, isContinuous: false, senderId: 0)
        try expect(ScrollWheel.payload(unknown)["senderId"] is NSNull, "sender 0 must serialize as null")
        let known = ScrollWheel.Fields(pointDeltaX: 0, pointDeltaY: 0, fixedDeltaX: 0, fixedDeltaY: 0,
                                       phase: 1, momentumPhase: 0, isContinuous: true,
                                       senderId: 0x1000_0000_0abc)
        try expectEqual(ScrollWheel.payload(known)["senderId"] as? UInt64, 0x1000_0000_0abc)
    }

    test("ScrollWheel.payload: serializes to JSON with every documented key") {
        let f = ScrollWheel.Fields(pointDeltaX: 1, pointDeltaY: 2, fixedDeltaX: 0.5, fixedDeltaY: 1,
                                   phase: 2, momentumPhase: 0, isContinuous: true, senderId: 42)
        let json = Bridge.jsonify(ScrollWheel.payload(f))
        for key in ["deltaX", "deltaY", "fixedDeltaX", "fixedDeltaY", "scrollPhase",
                    "momentumPhase", "isContinuous", "senderId"] {
            try expect(json.contains("\"\(key)\""), "missing \(key) in \(json)")
        }
    }

    test("ScrollWheel.read: pulls deltas and phase fields off a CGEvent") {
        let ev = makeScroll(dy: 5, dx: -2)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let f = ScrollWheel.read(ev)
        try expectEqual(f.pointDeltaY, 5)
        try expectEqual(f.pointDeltaX, -2)
        try expectEqual(f.phase, 2)
        try expectEqual(f.momentumPhase, 0)
        try expectEqual(f.isContinuous, true)
    }

    test("ScrollWheel.read: line-unit wheel event reports non-continuous") {
        let ev = makeScroll(dy: 1, dx: 0, units: .line)
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        let f = ScrollWheel.read(ev)
        try expectEqual(f.isContinuous, false)
        try expectEqual(f.phase, 0)
        try expect(f.fixedDeltaY != 0, "a line scroll carries a fixed-point delta")
    }

    test("ScrollWheel.senderId: a synthesized event has no HID sender") {
        try expectEqual(ScrollWheel.senderId(of: makeScroll(dy: 1, dx: 0)), 0)
    }
}
