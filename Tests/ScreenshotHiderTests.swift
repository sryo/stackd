import Foundation
import AppKit
import WebKit

// Tests for `Sources/ScreenshotHider.swift` + the `hideDuringScreenshot`
// manifest field.
//
// ScreenshotHider hides click-through panels while the macOS screenshot UI
// (`com.apple.screencaptureui`) is running — the Cmd-Shift-4/5 window
// picker otherwise highlights the always-on-top overlays instead of the
// windows beneath, and no public API makes a window picker-invisible while
// staying on top (NSWindow.sharingType is ignored on macOS 15+).
//
// Covered here: the manifest decode, the pure hide predicate
// (ScreenshotHidePolicy), the session state machine (ScreenshotSession),
// the StackWindow flag carry, hideAll against transparent off-screen
// panels, and the repinAllAfterScreenshot fan-out.
//
// NOT covered (manual verification only): the NSWorkspace
// runningApplications KVO actually firing on Cmd-Shift-4 (needs a real
// screenshot session), the restore round-trip, and the overlay tick's
// dormant-while-active gate.

func registerScreenshotHiderTests() {
    // MARK: - manifest decode

    test("manifest: hideDuringScreenshot defaults to nil when missing") {
        let json = """
        {"id":"x","name":"X","size":{"w":1,"h":1},"permissions":[]}
        """
        let m = try JSONDecoder().decode(StackManifest.self, from: Data(json.utf8))
        try expectEqual(m.hideDuringScreenshot, nil)
    }

    test("manifest: hideDuringScreenshot decodes true and false") {
        for flag in [true, false] {
            let json = """
            {"id":"x","name":"X","permissions":[],"hideDuringScreenshot":\(flag)}
            """
            let m = try JSONDecoder().decode(StackManifest.self, from: Data(json.utf8))
            try expectEqual(m.hideDuringScreenshot, flag)
        }
    }

    // MARK: - ScreenshotHidePolicy (pure predicate)

    test("ScreenshotHidePolicy hides visible click-through non-opted-out windows") {
        try expectEqual(ScreenshotHidePolicy.shouldHide(
            isVisible: true, ignoresMouseEvents: true, optedOut: false), true)
    }

    test("ScreenshotHidePolicy skips each negated input") {
        try expectEqual(ScreenshotHidePolicy.shouldHide(
            isVisible: false, ignoresMouseEvents: true, optedOut: false), false,
            "hidden window must not be snapshotted for restore")
        try expectEqual(ScreenshotHidePolicy.shouldHide(
            isVisible: true, ignoresMouseEvents: false, optedOut: false), false,
            "clickable window is picker-targetable legitimately")
        try expectEqual(ScreenshotHidePolicy.shouldHide(
            isVisible: true, ignoresMouseEvents: true, optedOut: true), false,
            "manifest opt-out wins")
    }

    test("ScreenshotHidePolicy matches only the screenshot UI bundle id") {
        try expectEqual(ScreenshotHidePolicy.isScreenshotApp("com.apple.screencaptureui"), true)
        try expectEqual(ScreenshotHidePolicy.isScreenshotApp("com.apple.finder"), false)
        try expectEqual(ScreenshotHidePolicy.isScreenshotApp(nil), false)
    }

    // MARK: - ScreenshotSession (pure state machine)

    test("ScreenshotSession transitions idle→hiding→idle exactly once each") {
        var s = ScreenshotSession()
        try expectEqual(s.screenshotUIAppeared(), true, "idle → hiding")
        try expectEqual(s.screenshotUIAppeared(), false, "double-appear is a no-op")
        try expectEqual(s.screenshotUIExited(), true, "hiding → idle")
        try expectEqual(s.screenshotUIExited(), false, "double-exit is a no-op")
    }

    test("ScreenshotSession exit without appear is a no-op") {
        var s = ScreenshotSession()
        try expectEqual(s.screenshotUIExited(), false)
        try expectEqual(s.screenshotUIAppeared(), true, "still armable afterwards")
    }

    // MARK: - StackWindow flag carry

    test("StackWindow carries hideDuringScreenshot and defaults to true") {
        let defaulted = StackWindow(
            frame: NSRect(x: 0, y: 0, width: 10, height: 10),
            clickThrough: true,
            schemeHandler: StackdSchemeHandler(runtimePath: "/nonexistent")
        )
        try expectEqual(defaulted.hideDuringScreenshot, true)
        let optedOut = StackWindow(
            frame: NSRect(x: 0, y: 0, width: 10, height: 10),
            clickThrough: true,
            schemeHandler: StackdSchemeHandler(runtimePath: "/nonexistent"),
            hideDuringScreenshot: false
        )
        try expectEqual(optedOut.hideDuringScreenshot, false)
    }

    // MARK: - hideAll skip branches

    test("ScreenshotHider.hideAll hides visible click-through panels and skips the rest") {
        // Fully transparent 1pt panels far off screen: ordered in at the
        // window server, invisible on the display.
        func panel(clickThrough: Bool, show: Bool) -> NSPanel {
            let p = NSPanel(contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                            styleMask: .borderless, backing: .buffered, defer: false)
            p.ignoresMouseEvents = clickThrough
            p.alphaValue = 0
            if show { p.orderFrontRegardless() }
            return p
        }
        let target = panel(clickThrough: true, show: true)
        let clickable = panel(clickThrough: false, show: true)
        let neverShown = panel(clickThrough: true, show: false)
        let optedOut = StackWindow(
            frame: NSRect(x: -9999, y: -9999, width: 1, height: 1),
            clickThrough: true,
            schemeHandler: StackdSchemeHandler(runtimePath: "/nonexistent"),
            hideDuringScreenshot: false
        )
        optedOut.alphaValue = 0
        optedOut.orderFrontRegardless()
        try expect(target.isVisible && clickable.isVisible && optedOut.isVisible,
                   "setup: panels must be ordered in")

        let hider = ScreenshotHider()
        hider.hideAll([target, clickable, neverShown, optedOut])
        try expectEqual(hider.hiddenCount, 1, "only the visible click-through panel qualifies")
        try expect(!target.isVisible, "the qualifying panel is ordered out")
        try expect(clickable.isVisible, "a clickable panel stays")
        try expect(optedOut.isVisible, "a stack that opted out stays")

        optedOut.orderOut(nil)
        for p in [target, clickable, neverShown] {
            p.orderOut(nil)
            p.close()
        }
    }

    // MARK: - overlay repin fan-out

    test("Overlay.repinAllAfterScreenshot force-repins live handles only") {
        let panelA = NSPanel(contentRect: .zero, styleMask: .borderless,
                             backing: .buffered, defer: true)
        let webA = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let a = OverlayHandle(id: 900, targetWID: 1, panel: panelA, webView: webA)
        Overlay.register(a)
        let panelB = NSPanel(contentRect: .zero, styleMask: .borderless,
                             backing: .buffered, defer: true)
        let webB = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let b = OverlayHandle(id: 901, targetWID: 2, panel: panelB, webView: webB)
        Overlay.register(b)
        b.detach()  // released — forceRepin must no-op

        Overlay.repinAllAfterScreenshot()
        try expectEqual(a.repinRequested, true, "live handle repinned")
        try expectEqual(b.repinRequested, false, "detached handle untouched")
        a.detach()
    }
}
