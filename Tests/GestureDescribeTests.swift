import AppKit
import Foundation

// `Gesture.describe` is the payload a gesture eventtap hands a stack. Events
// come from the vendored TouchEvents.c synthesizer and are never posted. The
// window server only attaches NSTouch objects to events it routes itself, so
// a synthesized event always reads as a gesture with no fingers; the finger
// bookkeeping is covered only by a live trackpad.
func registerGestureDescribeTests() {
    func synth(subtype: Int32, phase: Int32, extra: [CFString: Any] = [:]) -> CGEvent? {
        var info: [CFString: Any] = [
            kTLInfoKeyGestureSubtype: NSNumber(value: subtype),
            kTLInfoKeyGesturePhase: NSNumber(value: phase)
        ]
        for (k, v) in extra { info[k] = v }
        return tl_CGEventCreateFromGesture(info as CFDictionary, [] as CFArray)?.takeRetainedValue()
    }

    test("Gesture.describe: names the subtype and carries the phase with no fingers") {
        guard let ev = synth(subtype: 0x0B, phase: 2), let d = Gesture.describe(cgEvent: ev) else {
            throw Expectation(message: "no gesture description")
        }
        try expectEqual(d["subtype"] as? Int, 0x0B)
        try expectEqual(d["subtypeName"] as? String, "gesture")
        try expectEqual(d["gesturePhase"] as? String, "changed")
        try expectEqual(d["fingers"] as? Int, 0)
        try expectEqual((d["touches"] as? [[String: Any]])?.count, 0)
        try expectEqual((d["phases"] as? [String: Int])?.count, 0)
    }

    test("Gesture.describe: merges the motion of a magnify event") {
        guard let ev = synth(subtype: 0x08, phase: 2,
                             extra: [kTLInfoKeyMagnification: NSNumber(value: Float(0.5))]),
              let d = Gesture.describe(cgEvent: ev) else {
            throw Expectation(message: "no gesture description")
        }
        try expectEqual(d["magnification"] as? Double, 0.5)
        try expectEqual(d["gesturePhase"] as? String, "changed")
    }
}
