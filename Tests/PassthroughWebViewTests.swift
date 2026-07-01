import Foundation
import AppKit
import WebKit

// Tests for `Sources/PassthroughWebView.swift`.
//
// PassthroughWebView is the drag-inert WKWebView used by click-through
// surfaces. WebKit registers every WKWebView for the draggable pasteboard
// types via the public `registerForDraggedTypes(_:)`, which makes even an
// `ignoresMouseEvents` panel a drag-destination — a Finder drag over a
// click-through stack targeted the invisible overlay instead of the window
// beneath. The subclass suppresses registration while `dragPassthrough`
// is true but remembers the requested types, so flipping click-through off
// (bar hover-flip, sd.window.setClickThrough) restores normal drops.
//
// Everything here runs headlessly: WKWebView construction is main-thread
// safe without orderFront (same constraint set as OverlayTests), and
// `NSView.registeredDraggedTypes` is a public, synchronous getter.
//
// NOT covered here (runtime verification only): whether an empty
// registered-types list actually reroutes a live Finder drag to the window
// beneath the panel — that is WindowServer behavior, exercised manually
// (drag a file over a click-through stack onto TextEdit).

func registerPassthroughWebViewTests() {
    func makeWebView(passthrough: Bool) -> PassthroughWebView {
        PassthroughWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration(),
            dragPassthrough: passthrough
        )
    }

    test("PassthroughWebView suppresses drag registration while passthrough") {
        let v = makeWebView(passthrough: true)
        v.registerForDraggedTypes([.fileURL])
        try expect(v.registeredDraggedTypes.isEmpty,
                   "expected no registered types, got \(v.registeredDraggedTypes)")
    }

    test("PassthroughWebView registers normally when not passthrough") {
        let v = makeWebView(passthrough: false)
        v.registerForDraggedTypes([.fileURL])
        try expect(v.registeredDraggedTypes.contains(.fileURL),
                   "expected .fileURL registered, got \(v.registeredDraggedTypes)")
    }

    test("PassthroughWebView is drag-inert immediately after init") {
        // WebKit registers its own drag types during (or shortly after)
        // init; whatever it asked for must already be suppressed on a
        // passthrough instance — no window/navigation needed.
        let v = makeWebView(passthrough: true)
        try expect(v.registeredDraggedTypes.isEmpty,
                   "expected fresh passthrough instance empty, got \(v.registeredDraggedTypes)")
    }

    test("PassthroughWebView toggle restores deferred types and re-suppresses") {
        let v = makeWebView(passthrough: true)
        v.registerForDraggedTypes([.fileURL, .string])
        try expect(v.registeredDraggedTypes.isEmpty, "suppressed register leaked through")
        v.dragPassthrough = false
        try expect(v.registeredDraggedTypes.contains(.fileURL),
                   "expected deferred .fileURL live after toggle, got \(v.registeredDraggedTypes)")
        try expect(v.registeredDraggedTypes.contains(.string),
                   "expected deferred .string live after toggle, got \(v.registeredDraggedTypes)")
        v.dragPassthrough = true
        try expect(v.registeredDraggedTypes.isEmpty,
                   "expected re-suppression on toggle back, got \(v.registeredDraggedTypes)")
    }

    test("StackWindow clickThrough=true builds a drag-inert webview") {
        let win = StackWindow(
            frame: NSRect(x: 0, y: 0, width: 10, height: 10),
            clickThrough: true,
            schemeHandler: StackdSchemeHandler(runtimePath: "/nonexistent")
        )
        // Never ordered front — nothing appears during the suite.
        try expect(win.webView.registeredDraggedTypes.isEmpty,
                   "expected clickThrough StackWindow webview drag-inert, got \(win.webView.registeredDraggedTypes)")
        try expect((win.webView as? PassthroughWebView)?.dragPassthrough == true,
                   "expected PassthroughWebView with dragPassthrough=true")
    }

    test("StackWindow.setClickThrough flips drag policy in lockstep") {
        let win = StackWindow(
            frame: NSRect(x: 0, y: 0, width: 10, height: 10),
            clickThrough: true,
            schemeHandler: StackdSchemeHandler(runtimePath: "/nonexistent")
        )
        win.setClickThrough(false)
        try expect(win.ignoresMouseEvents == false, "ignoresMouseEvents should follow setClickThrough")
        try expect((win.webView as? PassthroughWebView)?.dragPassthrough == false,
                   "dragPassthrough should follow setClickThrough(false)")
        win.setClickThrough(true)
        try expect((win.webView as? PassthroughWebView)?.dragPassthrough == true,
                   "dragPassthrough should follow setClickThrough(true)")
        try expect(win.webView.registeredDraggedTypes.isEmpty,
                   "expected drag-inert again after setClickThrough(true), got \(win.webView.registeredDraggedTypes)")
    }

    test("Overlay.makeOverlayWebView is always passthrough") {
        let v = Overlay.makeOverlayWebView(size: CGSize(width: 5, height: 5))
        try expect(v.dragPassthrough, "overlay webviews are click-through by contract")
        try expect(v.registeredDraggedTypes.isEmpty,
                   "expected overlay webview drag-inert, got \(v.registeredDraggedTypes)")
    }
}
