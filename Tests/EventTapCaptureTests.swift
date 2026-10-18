import AppKit
import CoreGraphics
import Foundation

// An eventtap callback's `onTap_<callback>` payload is built in two steps:
// `EventTapCapture` reads the CGEvent inside the tap callback, and its
// `payload` is built afterwards, off the blocking callback. The events here
// are synthesized and never posted; no tap is installed.
func registerEventTapCaptureTests() {
    func keyDown(_ keyCode: CGKeyCode, at point: CGPoint, flags: CGEventFlags) -> CGEvent? {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return nil }
        e.location = point
        e.flags = flags
        return e
    }

    func mouse(_ type: CGEventType, at point: CGPoint, delta: (Int64, Int64) = (0, 0)) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                              mouseButton: .left) else { return nil }
        e.setIntegerValueField(.mouseEventDeltaX, value: delta.0)
        e.setIntegerValueField(.mouseEventDeltaY, value: delta.1)
        return e
    }

    test("eventtap capture: a key event's payload carries type, keyCode, flags and the truncated location") {
        guard let e = keyDown(49, at: CGPoint(x: 10.7, y: 20.2), flags: .maskCommand) else {
            throw Expectation(message: "no synthetic key event")
        }
        let capture = EventTapCapture(type: .keyDown, event: e, phase: nil)
        try expectEqual(Bridge.jsonify(capture.payload),
                        #"{"flags":\#(CGEventFlags.maskCommand.rawValue),"keyCode":49,"type":"keyDown","x":10,"y":20}"#)
    }

    test("eventtap capture: the payload is the event as captured, not as it is later") {
        guard let e = keyDown(49, at: CGPoint(x: 1, y: 2), flags: .maskShift) else {
            throw Expectation(message: "no synthetic key event")
        }
        let capture = EventTapCapture(type: .keyDown, event: e, phase: nil)
        e.setIntegerValueField(.keyboardEventKeycode, value: 0)
        e.location = CGPoint(x: 300, y: 400)
        e.flags = []
        let p = capture.payload
        try expectEqual(p["keyCode"] as? Int64, 49)
        try expectEqual(p["x"] as? Int, 1)
        try expectEqual(p["y"] as? Int, 2)
        try expectEqual(p["flags"] as? UInt64, CGEventFlags.maskShift.rawValue)
    }

    test("eventtap capture: pointer motion carries its frame-to-frame delta; a click does not") {
        guard let moved = mouse(.mouseMoved, at: CGPoint(x: 5, y: 6), delta: (3, -2)),
              let dragged = mouse(.leftMouseDragged, at: CGPoint(x: 5, y: 6), delta: (-1, 4)),
              let rightDragged = mouse(.rightMouseDragged, at: CGPoint(x: 5, y: 6), delta: (7, 0)),
              let down = mouse(.leftMouseDown, at: CGPoint(x: 5, y: 6)) else {
            throw Expectation(message: "no synthetic mouse event")
        }
        let m = EventTapCapture(type: .mouseMoved, event: moved, phase: nil).payload
        try expectEqual(m["deltaX"] as? Double, 3)
        try expectEqual(m["deltaY"] as? Double, -2)
        let d = EventTapCapture(type: .leftMouseDragged, event: dragged, phase: nil).payload
        try expectEqual(d["deltaX"] as? Double, -1)
        try expectEqual(d["deltaY"] as? Double, 4)
        let r = EventTapCapture(type: .rightMouseDragged, event: rightDragged, phase: nil).payload
        try expectEqual(r["deltaX"] as? Double, 7)
        let c = EventTapCapture(type: .leftMouseDown, event: down, phase: nil).payload
        try expectEqual(c["deltaX"] == nil, true)
        try expectEqual(c["type"] as? String, "leftMouseDown")
    }

    test("eventtap capture: every pointer-motion type that carries a delta is one a manifest can tap") {
        for type in EventTapCapture.motionTypes {
            let name = EventTapRegistry.name(for: type)
            try expectEqual(EventTapRegistry.parse(name), type, "motion type \(type.rawValue) has no eventtap name")
        }
    }

    test("eventtap capture: a scroll event carries the scroll fields read at capture") {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: -4, wheel2: 2, wheel3: 0) else {
            throw Expectation(message: "no synthetic scroll event")
        }
        let expected = ScrollWheel.payload(ScrollWheel.read(e))
        let capture = EventTapCapture(type: .scrollWheel, event: e, phase: nil)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 99)
        let p = capture.payload
        for key in expected.keys.sorted() {
            try expectEqual(Bridge.jsonify([key: p[key] ?? "missing"]), Bridge.jsonify([key: expected[key]!]))
        }
        try expectEqual(p["type"] as? String, "scrollWheel")
    }

    test("eventtap capture: a gesture is described from the event as captured") {
        let info: [CFString: Any] = [
            kTLInfoKeyGestureSubtype: NSNumber(value: Int32(0x08)),
            kTLInfoKeyGesturePhase: NSNumber(value: Int32(2)),
            kTLInfoKeyMagnification: NSNumber(value: Float(0.5)),
        ]
        guard let e = tl_CGEventCreateFromGesture(info as CFDictionary, [] as CFArray)?.takeRetainedValue() else {
            throw Expectation(message: "no synthetic gesture event")
        }
        let capture = EventTapCapture(type: Gesture.cgEventType, event: e, phase: nil)
        // Re-typing the tap's event as a plain gesture drops its magnify
        // motion; the captured event still reads as the magnify it was.
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 0x0B)
        try expectEqual(Gesture.describe(cgEvent: e)?["magnification"] == nil, true)
        let p = capture.payload
        try expectEqual(p["type"] as? String, "gesture")
        try expectEqual(p["magnification"] as? Double, 0.5)
        try expectEqual(p["gesturePhase"] as? String, "changed")
    }

    test("eventtap capture: a rect-gate phase is carried only when the handler emits one") {
        guard let e = mouse(.mouseMoved, at: CGPoint(x: 1, y: 1)) else {
            throw Expectation(message: "no synthetic mouse event")
        }
        try expectEqual(EventTapCapture(type: .mouseMoved, event: e, phase: "leave").payload["phase"] as? String, "leave")
        try expectEqual(EventTapCapture(type: .mouseMoved, event: e, phase: nil).payload["phase"] == nil, true)
    }
}
