import Foundation

// Tests for `Bridge.eventTapKey` — the EventTapRegistry key shared by a
// manifest eventtap and the sd.events.setTapRects calls that gate it.

func registerEventTapKeyTests() {
    test("eventTapKey: instances of one stack gate their taps separately") {
        // A display:"all" stack runs one bridge per display; with a shared
        // key each instance's setTapRects would overwrite the others' rects
        // and one instance's enter/leave state would mask the rest.
        let a = NSObject(), b = NSObject()
        let ka = Bridge.eventTapKey(stackId: "framemaster", callback: "cornerClick", owner: a)
        try expect(ka != Bridge.eventTapKey(stackId: "framemaster", callback: "cornerClick", owner: b))
        try expectEqual(ka, Bridge.eventTapKey(stackId: "framemaster", callback: "cornerClick", owner: a))
    }

    test("eventTapKey: callbacks of one instance stay separate") {
        let a = NSObject()
        try expect(Bridge.eventTapKey(stackId: "s", callback: "x", owner: a)
                   != Bridge.eventTapKey(stackId: "s", callback: "y", owner: a))
    }
}
