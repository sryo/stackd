import Foundation
import AppKit

// The window.* primitives that act on the stack's own panel
// (Sources/BridgeWindow.swift): each parses its request, hops to main, and
// answers true once it acted on the StackWindow hosting the page — false on
// a bad request or when the page isn't in a StackWindow. The panels here are
// never ordered front, so nothing appears on screen.

private func panelPage(invocable: Bool = false) throws -> (StackWindow, BridgedPage) {
    let win = StackWindow(
        frame: NSRect(x: 0, y: 0, width: 10, height: 10),
        clickThrough: true,
        schemeHandler: StackdSchemeHandler(runtimePath: "/nonexistent"),
        invocable: invocable
    )
    return (win, try BridgedPage(webView: win.webView))
}

func registerSelfPanelPrimitivesTests() {
    test("self panel: every window.* primitive answers false off a StackWindow") {
        let page = try BridgedPage()
        let calls = [
            #"{type: "window.invoke", requestId: 1}"#,
            #"{type: "window.dismiss", requestId: 2}"#,
            #"{type: "window.setAlpha", value: 0.5, requestId: 3}"#,
            #"{type: "window.setFrame", x: 1, y: 2, requestId: 4}"#,
            #"{type: "window.setClickThrough", value: false, requestId: 5}"#,
        ]
        for (i, call) in calls.enumerated() {
            try expectEqual(page.answer(requestId: i + 1, call), "false", call)
        }
    }

    test("self panel: a malformed request answers false and leaves the panel alone") {
        let (win, page) = try panelPage()
        win.alphaValue = 0.75
        try expectEqual(page.answer(requestId: 1, #"{type: "window.setAlpha", value: true, requestId: 1}"#), "false")
        try expectEqual(page.answer(requestId: 2, #"{type: "window.setFrame", x: "a", y: 2, requestId: 2}"#), "false")
        try expectEqual(page.answer(requestId: 3, #"{type: "window.setClickThrough", value: 0, requestId: 3}"#), "false")
        try expectEqual(win.alphaValue, 0.75)
        try expect(win.ignoresMouseEvents, "click-through untouched")
    }

    test("self panel: setAlpha, setFrame and setClickThrough act on the panel and answer true") {
        let (win, page) = try panelPage()
        try expectEqual(page.answer(requestId: 1, #"{type: "window.setAlpha", value: 0.25, requestId: 1}"#), "true")
        try expectEqual(win.alphaValue, 0.25)
        try expectEqual(page.answer(requestId: 2, #"{type: "window.setFrame", x: 5, y: 6, w: 30, h: 40, requestId: 2}"#), "true")
        try expectEqual(win.frame.size, NSSize(width: 30, height: 40))
        try expectEqual(page.answer(requestId: 3, #"{type: "window.setClickThrough", value: false, requestId: 3}"#), "true")
        try expect(!win.ignoresMouseEvents, "panel now takes clicks")
    }

    test("self panel: invoke and dismiss answer false on a panel that isn't invocable") {
        let (win, page) = try panelPage(invocable: false)
        try expectEqual(page.answer(requestId: 1, #"{type: "window.invoke", requestId: 1}"#), "false")
        try expectEqual(page.answer(requestId: 2, #"{type: "window.dismiss", requestId: 2}"#), "false")
        try expect(!win.isVisible, "panel stayed hidden")
    }

    test("self panel: dismiss answers true on an invocable panel") {
        let (win, page) = try panelPage(invocable: true)
        try expectEqual(page.answer(requestId: 1, #"{type: "window.dismiss", requestId: 1}"#), "true")
        try expect(!win.isVisible)
    }
}
