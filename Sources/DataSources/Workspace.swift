import AppKit
import ApplicationServices

// Two related sources colocated: which app is frontmost, and what window
// has focus inside it. NSWorkspace fires on app switches; for within-app
// focus changes a future iteration installs an AXObserver per-app on
// kAXFocusedWindowChangedNotification. v0 just slow-ticks instead.

final class WorkspaceObserver: RefCountedObserver {
    static let shared = WorkspaceObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.fire() }
        return Token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}

enum Workspace {
    static func frontmostApp() -> [String: Any]? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return [
            "pid": Int(app.processIdentifier),
            "name": app.localizedName ?? "",
            "bundleId": app.bundleIdentifier ?? "",
            "active": app.isActive
        ]
    }
}

enum Windows {
    // Focused window for the frontmost app, via Accessibility.
    static func focused() -> [String: Any]? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        // Cap blocking calls — an unresponsive app shouldn't hang the daemon.
        AXUIElementSetMessagingTimeout(appEl, 0.1)

        var focusedRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef)
        guard err == .success, let focused = focusedRef else { return nil }
        // swiftlint:disable:next force_cast
        let win = focused as! AXUIElement

        var titleRef: AnyObject?
        _ = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""

        var posRef: AnyObject?
        var sizeRef: AnyObject?
        _ = AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
        _ = AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
        var pt = CGPoint.zero
        var sz = CGSize.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &sz) }

        // Recover CGWindowID via the private SPI so per-window-id consumers
        // (sd.windows.byId, tiler-style stacks) can target this exact window.
        var winId: CGWindowID = 0
        var idVal: Int? = nil
        if let getWindow = AXShim.getWindow, getWindow(win, &winId) == .success {
            idVal = Int(winId)
        }

        var out: [String: Any] = [
            "app": app.localizedName ?? "",
            "pid": Int(pid),
            "title": title,
            "frame": ["x": Int(pt.x), "y": Int(pt.y), "w": Int(sz.width), "h": Int(sz.height)]
        ]
        if let id = idVal { out["id"] = id }
        return out
    }

    // Actions all operate on the AX focused window of the frontmost app.
    // Per-window-id actions (move an arbitrary background window) require
    // mapping CGWindowID → AXUIElement, which is the private SPI
    // `_AXUIElementGetWindow`. Not yet vendored.

    private static func focusedWindowEl() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref)
        guard err == .success, let win = ref else { return nil }
        return (win as! AXUIElement)
    }

    @discardableResult
    static func setFocusedFrame(x: Double, y: Double, w: Double, h: Double) -> Bool {
        guard let win = focusedWindowEl() else { return false }
        var pos  = CGPoint(x: x, y: y)
        var size = CGSize(width: w, height: h)
        guard let posVal  = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize,  &size) else { return false }
        let posOK  = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        let sizeOK = AXUIElementSetAttributeValue(win, kAXSizeAttribute     as CFString, sizeVal)
        return posOK == .success && sizeOK == .success
    }

    @discardableResult
    static func minimizeFocused(_ value: Bool) -> Bool {
        guard let win = focusedWindowEl() else { return false }
        return AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    static func fullscreenFocused(_ value: Bool) -> Bool {
        guard let win = focusedWindowEl() else { return false }
        return AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    static func raiseFocused() -> Bool {
        guard let win = focusedWindowEl() else { return false }
        return AXUIElementPerformAction(win, kAXRaiseAction as CFString) == .success
    }

    // All on-screen normal windows from CGWindowList.
    static func all() -> [[String: Any]] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) else { return [] }
        let list = raw as! [[String: Any]]
        return list.compactMap { info -> [String: Any]? in
            guard let num   = info[kCGWindowNumber as String]    as? Int,
                  let layer = info[kCGWindowLayer  as String]    as? Int,
                  layer == 0,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let pid   = info[kCGWindowOwnerPID  as String] as? Int,
                  let bounds = info[kCGWindowBounds as String]   as? [String: CGFloat]
            else { return nil }
            return [
                "id": num,
                "app": owner,
                "pid": pid,
                "title": info[kCGWindowName as String] as? String ?? "",
                "frame": [
                    "x": Int(bounds["X"] ?? 0),
                    "y": Int(bounds["Y"] ?? 0),
                    "w": Int(bounds["Width"] ?? 0),
                    "h": Int(bounds["Height"] ?? 0)
                ]
            ]
        }
    }
}
