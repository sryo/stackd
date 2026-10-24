import AppKit
import ApplicationServices

// sd.ax.elementAtPosition(handle, x, y): hs.axuielement's elementAtPosition
// on any element, most usefully an application. Asking the app instead of
// the system-wide element finds its own element under the point even when
// another app's transparent layer is on top.

func registerAXElementAtPositionTests() {
    test("AX.elementAtPosition is nil for a handle the store doesn't hold") {
        try expectEqual(AX.elementAtPosition(handle: 999_999, x: 10, y: 10, store: AX.HandleStore()), nil)
    }

    test("AX.elementAtPosition asks the app for its element under the point") {
        let display = CGDisplayBounds(CGMainDisplayID())
        try withAXVictim(at: CGPoint(x: display.maxX - 400, y: display.maxY - 48)) { pid, _ in
            let store = AX.HandleStore()
            let app = AX.application(pid: pid, store: store)
            guard let win = AX.children(handle: app, store: store)?.first,
                  let position = AX.attribute(handle: win, name: kAXPositionAttribute, store: store) as? [String: Double],
                  let x = position["x"], let y = position["y"] else {
                throw Expectation(message: "victim window has no position")
            }
            guard let hit = AX.elementAtPosition(handle: app, x: Float(x + 200), y: Float(y + 10), store: store) else {
                throw Expectation(message: "no element at the victim's title bar")
            }
            try expectEqual(AX.role(handle: hit, store: store), kAXWindowRole as String)
        }
    }
}
