import CoreGraphics
import Foundation

// Every event stackd posts (sd.events.type / key / scroll / click) carries
// EventsSynth.marker in eventSourceUserData, and a tap payload built from
// one says `synthetic: true`, so a stack can tell stackd's own input from the
// user's. The events are built and inspected here, never posted.
func registerEventsSynthTests() {
    test("EventsSynth: every event it builds is marked synthetic") {
        let built: [(String, [CGEvent]?)] = [
            ("type", EventsSynth.typeEvents("hi")),
            ("key", EventsSynth.keyEvents("cmd+v")),
            ("scroll", EventsSynth.scrollEvents(dx: 0, dy: 5)),
            ("click", EventsSynth.clickEvents(x: 10, y: 20, button: "left")),
            ("right click", EventsSynth.clickEvents(x: 10, y: 20, button: "right")),
        ]
        for (name, events) in built {
            guard let events, !events.isEmpty else { throw Expectation(message: "\(name) built no events") }
            for e in events {
                try expect(EventsSynth.isSynthetic(e), "\(name) event not marked")
            }
        }
    }

    test("EventsSynth: an unknown key builds nothing") {
        try expectEqual(EventsSynth.keyEvents("cmd+notakey") == nil, true)
    }

    test("EventsSynth: an event from elsewhere is not synthetic") {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                              mouseCursorPosition: .zero, mouseButton: .left) else {
            throw Expectation(message: "no event")
        }
        try expect(!EventsSynth.isSynthetic(e))
        e.setIntegerValueField(.eventSourceUserData, value: 42)
        try expect(!EventsSynth.isSynthetic(e), "another tool's user data is not stackd's marker")
    }

    test("eventtap capture: a synthetic event's payload says so; a user's keeps its shape") {
        guard let click = EventsSynth.clickEvents(x: 10, y: 20, button: "left")?.first,
              let user = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: CGPoint(x: 10, y: 20), mouseButton: .left) else {
            throw Expectation(message: "no events")
        }
        try expectEqual(EventTapCapture(type: .leftMouseDown, event: click, phase: nil).payload["synthetic"] as? Bool, true)
        try expect(EventTapCapture(type: .leftMouseDown, event: user, phase: nil).payload["synthetic"] == nil)
    }
}
