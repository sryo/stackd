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
// Headlessly testable and covered here: the manifest decode, the pure
// hide predicate (ScreenshotHidePolicy), the session state machine
// (ScreenshotSession), the StackWindow flag carry, hideAll's skip
// branches against never-ordered-front panels, and the
// repinAllAfterScreenshot fan-out.
//
// NOT testable here (manual verification only): the NSWorkspace
// runningApplications KVO actually firing on Cmd-Shift-4 (needs a real
// screenshot session), the orderOut/orderFrontRegardless round-trip on
// visible windows (ordering a window front during the suite is out of
// scope per the OverlayTests constraint), and the BridgeOverlay
// vsync-tick gate interaction.

func registerScreenshotHiderTests() {
    // MARK: - manifest decode

    test("manifest: hideDuringScreenshot defaults to nil when missing") {
        let json = """
        {"id":"x","name":"X","size":{"w":1,"h":1},"permissions":[]}
        """
        let m = try JSONDecoder().decode(StackManifest.self, from: Data(json.utf8))
        try expectEqual(m.hideDuringScreenshot, nil)
        // The spawn-side default: nil → hide.
        try expectEqual(m.hideDuringScreenshot ?? true, true)
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

    test("ScreenshotHider.hideAll skips invisible, clickable, and opted-out windows") {
        // All panels here are defer:true and never ordered front —
        // isVisible == false, so the visibility skip-branch applies to the
        // plain panel, and the opted-out StackWindow exercises the opt-out
        // branch regardless. Nothing appears during the suite; the positive
        // hide path (a VISIBLE click-through panel) is manual-verification
        // territory.
        let clickThroughPanel = NSPanel(contentRect: .zero, styleMask: .borderless,
                                        backing: .buffered, defer: true)
        clickThroughPanel.ignoresMouseEvents = true
        let clickablePanel = NSPanel(contentRect: .zero, styleMask: .borderless,
                                     backing: .buffered, defer: true)
        clickablePanel.ignoresMouseEvents = false
        let optedOut = StackWindow(
            frame: NSRect(x: 0, y: 0, width: 10, height: 10),
            clickThrough: true,
            schemeHandler: StackdSchemeHandler(runtimePath: "/nonexistent"),
            hideDuringScreenshot: false
        )
        let hider = ScreenshotHider()
        hider.hideAll([clickThroughPanel, clickablePanel, optedOut])
        try expectEqual(hider.hiddenCount, 0,
                        "no window qualified: invisible / clickable / opted-out")
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
