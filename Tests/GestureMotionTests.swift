import Foundation
import CoreGraphics

// Tests for `Gesture.motion(cgEvent:)` in Sources/DataSources/Input.swift —
// magnification / rotation / swipe direction / phase read off a gesture
// CGEvent (type 29). Events come from the vendored TouchEvents.c
// synthesizer (the same private encoding the window server produces) and
// are never posted.
func registerGestureMotionTests() {

    func synth(subtype: Int32, phase: Int32 = 2, extra: [CFString: Any] = [:]) -> CGEvent? {
        var info: [CFString: Any] = [
            kTLInfoKeyGestureSubtype: NSNumber(value: subtype),
            kTLInfoKeyGesturePhase: NSNumber(value: phase)
        ]
        for (k, v) in extra { info[k] = v }
        return tl_CGEventCreateFromGesture(info as CFDictionary, [] as CFArray)?.takeRetainedValue()
    }

    test("Gesture.motion: magnify carries its magnification and phase") {
        guard let ev = synth(subtype: 0x08, phase: 2,
                             extra: [kTLInfoKeyMagnification: NSNumber(value: Float(0.25))]) else {
            throw Expectation(message: "synthesizer returned nil")
        }
        let m = Gesture.motion(cgEvent: ev)
        try expectEqual(m["magnification"] as? Double, 0.25)
        try expectEqual(m["gesturePhase"] as? String, "changed")
        try expect(m["rotation"] == nil, "no rotation on a magnify event")
    }

    test("Gesture.motion: rotate carries rotation in degrees") {
        guard let ev = synth(subtype: 0x05, phase: 1,
                             extra: [kTLInfoKeyRotation: NSNumber(value: Float(-12.5))]) else {
            throw Expectation(message: "synthesizer returned nil")
        }
        let m = Gesture.motion(cgEvent: ev)
        try expectEqual(m["rotation"] as? Double, -12.5)
        try expectEqual(m["gesturePhase"] as? String, "began")
        try expect(m["magnification"] == nil, "no magnification on a rotate event")
    }

    test("Gesture.motion: swipe names its direction") {
        let cases: [(Int32, String)] = [(1, "up"), (2, "down"), (4, "left"), (8, "right")]
        for (raw, name) in cases {
            guard let ev = synth(subtype: 0x10, phase: 4,
                                 extra: [kTLInfoKeySwipeDirection: NSNumber(value: raw)]) else {
                throw Expectation(message: "synthesizer returned nil")
            }
            let m = Gesture.motion(cgEvent: ev)
            try expectEqual(m["swipeDirection"] as? String, name, "direction \(raw)")
            try expectEqual(m["gesturePhase"] as? String, "ended")
        }
    }

    test("Gesture.motion: a plain gesture event carries only its phase") {
        guard let ev = synth(subtype: 0x0B, phase: 0) else {
            throw Expectation(message: "synthesizer returned nil")
        }
        let m = Gesture.motion(cgEvent: ev)
        try expectEqual(m["gesturePhase"] as? String, "none")
        try expect(m["magnification"] == nil && m["rotation"] == nil && m["swipeDirection"] == nil,
                   "no motion keys: \(m)")
    }

    test("Gesture.motion: reads subtype, magnification and phase straight off the CGEvent fields") {
        let ev = CGEvent(source: nil)!
        ev.type = Gesture.cgEventType
        ev.setIntegerValueField(CGEventField(rawValue: 110)!, value: 0x08)
        ev.setDoubleValueField(CGEventField(rawValue: 113)!, value: -0.5)
        ev.setIntegerValueField(CGEventField(rawValue: 132)!, value: 8)
        let m = Gesture.motion(cgEvent: ev)
        try expectEqual(m["magnification"] as? Double, -0.5)
        try expectEqual(m["gesturePhase"] as? String, "cancelled")
    }
}
