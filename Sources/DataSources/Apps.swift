import AppKit
import ApplicationServices
import CoreGraphics

// Two domains, one workspace:
//   `App`  + `FrontmostAppObserver` — single-notification, high-fire-rate
//                                     (didActivateApplicationNotification only)
//   `Apps` + `AppsObserver`         — five-notification list-rebuild
//                                     (launch/terminate/hide/unhide/activate)
// Both subscribe to NSWorkspace.shared.notificationCenter but with different
// lifetimes and fire shapes — keep the observers separate, just colocate them.
// Window-related code (focused window, lifecycle, per-id actions, focus
// observer) lives in Windows.swift — they share the AX + CGWindowList machinery.

enum App {
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

final class FrontmostAppObserver: RefCountedObserver {
    static let shared = FrontmostAppObserver()
    private override init() { super.init() }

    override func install() -> Token {
        installNotifications([
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification)
        ])
    }
}

// Running apps as a signal + the four imperative verbs every launcher /
// dock / kill-switch eventually needs. Apps without a bundle id (rare but
// real — some kernel-side helpers, some old apps) are filtered out — there's
// no way to launch / focus them by ID anyway.

enum Apps {
    static func running() -> [[String: Any]] {
        NSWorkspace.shared.runningApplications.compactMap { app -> [String: Any]? in
            guard let bundleId = app.bundleIdentifier else { return nil }
            // activationPolicy mirrors NSApplication.ActivationPolicy:
            //   "regular"    — normal Dock-visible UI app (Lua's app:kind() == 1)
            //   "accessory"  — LSUIElement / background-with-UI (status item, etc.)
            //   "prohibited" — never appears in UI (XPC helpers, etc.)
            // Lets consumers filter helper processes out the same way Hammerspoon
            // does. Used by AppTimeout to skip background helpers.
            let policy: String = {
                switch app.activationPolicy {
                case .regular:    return "regular"
                case .accessory:  return "accessory"
                case .prohibited: return "prohibited"
                @unknown default: return "regular"
                }
            }()
            var entry: [String: Any] = [
                "pid":              Int(app.processIdentifier),
                "bundleId":         bundleId,
                "name":             app.localizedName ?? "",
                "active":           app.isActive,
                "hidden":           app.isHidden,
                "activationPolicy": policy
            ]
            if let date = app.launchDate {
                entry["launchedAt"] = date.timeIntervalSince1970
            }
            return entry
        }
    }

    @discardableResult
    static func launch(bundleId: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        return true
    }

    /// Focus the app if running; otherwise launch it. Matches user intent
    /// for both launcher hotkeys ("open Safari") and "go to my Calendar".
    @discardableResult
    static func focus(bundleId: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            return app.activate(options: [.activateAllWindows])
        }
        return launch(bundleId: bundleId)
    }

    @discardableResult
    static func kill(bundleId: String, force: Bool = false) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return false }
        return force ? app.forceTerminate() : app.terminate()
    }

    @discardableResult
    static func hide(bundleId: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return false }
        return app.hide()
    }

    // MARK: - Curated AX readers (pid-based)
    //
    // Mirrors hs.application's menu / findMenuItem / selectMenuItem /
    // visibleWindows / hide / unhide surface. The bundle-id `hide()` above
    // is the bundleId variant; the pid `hide(pid:)` below is the per-app
    // variant that matches the new sd.apps.* shape. All AX walks cap the
    // messaging timeout at 100ms (same as Windows.swift) so an unresponsive
    // app can't stall the daemon.

    // Element keyed by its kAXMenuBarAttribute (the app's AXMenuBar). Apps
    // that don't surface a menu bar (background helpers, agents) return nil.
    private static func menuBarElement(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &ref) == .success,
              let bar = ref else { return nil }
        // swiftlint:disable:next force_cast
        return (bar as! AXUIElement)
    }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func axBool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private static func axChildren(_ el: AXUIElement) -> [AXUIElement] {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    /// Recursive walk producing nested `{title, role, enabled?, marked?,
    /// shortcut?, children?}` dicts. The top-level call is the menu bar; its
    /// children are AXMenuBarItem (top-level menus); each of those has an
    /// AXMenu child whose children are AXMenuItem entries. Submenus live as
    /// an AXMenu child inside the AXMenuItem — same shape Hammerspoon's
    /// _getMenuStructure surfaces. Empty `children` is preserved as `[]` for
    /// AXMenuBarItem / submenu items so consumers can distinguish "no
    /// submenu" from "menu was unreadable".
    private static func walkMenu(_ el: AXUIElement) -> [String: Any] {
        AXUIElementSetMessagingTimeout(el, 0.1)
        var out: [String: Any] = [:]
        if let title = axString(el, kAXTitleAttribute) { out["title"] = title }
        if let role  = axString(el, kAXRoleAttribute)  { out["role"]  = role }
        if let enabled = axBool(el, kAXEnabledAttribute) { out["enabled"] = enabled }
        // AXMenuItemMarkChar is unset (kAXErrorNoValue) when the item isn't
        // ticked; presence of any value means marked. We surface this as a
        // bool so JS consumers don't have to special-case the ✓ character.
        var markRef: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXMenuItemMarkCharAttribute as CFString, &markRef) == .success,
           markRef != nil {
            out["marked"] = true
        }
        // Keyboard shortcut as a short string ("⌘S"). cmdChar is the key
        // glyph; cmdModifiers is the modifier mask (kAXMenuItemModifierNoCommand
        // means no shortcut). Best-effort — apps without shortcut attributes
        // simply omit the key.
        if let cmdChar = axString(el, kAXMenuItemCmdCharAttribute), !cmdChar.isEmpty {
            var modsRef: AnyObject?
            var mods: Int = 0
            if AXUIElementCopyAttributeValue(el, kAXMenuItemCmdModifiersAttribute as CFString, &modsRef) == .success,
               let n = modsRef as? NSNumber {
                mods = n.intValue
            }
            // kAXMenuItemModifierNoCommand = 0x1 means "no shortcut". The
            // remaining bits are shift (0x4), option/alt (0x2), control (0x8);
            // cmd is always present unless NoCommand is set.
            if (mods & 0x1) == 0 {
                var shortcut = ""
                if (mods & 0x8) != 0 { shortcut += "⌃" }
                if (mods & 0x2) != 0 { shortcut += "⌥" }
                if (mods & 0x4) != 0 { shortcut += "⇧" }
                shortcut += "⌘" + cmdChar
                out["shortcut"] = shortcut
            }
        }
        // Recurse — every AXMenuBar / AXMenuBarItem / AXMenuItem with a
        // submenu has its real children wrapped in a single AXMenu child.
        // Unwrap it the way Hammerspoon does so the JSON tree matches the
        // user's mental model ("File" -> ["New", "Open", ...] not
        // ["File" -> [AXMenu -> [...]]]).
        let kids = axChildren(el)
        if !kids.isEmpty {
            var effective = kids
            if kids.count == 1,
               let firstRole = axString(kids[0], kAXRoleAttribute),
               firstRole == (kAXMenuRole as String) {
                effective = axChildren(kids[0])
            }
            // Only emit `children` when the element actually has menu structure.
            // Leaves (AXMenuItem with no submenu) keep the key absent.
            if !effective.isEmpty || (out["role"] as? String) == (kAXMenuBarRole as String) {
                out["children"] = effective.map { walkMenu($0) }
            }
        }
        return out
    }

    /// Full menu-bar tree as a nested dict. Root is the AXMenuBar (carries
    /// `children` of top-level menus). Returns nil if the app has no menu bar
    /// (background helpers, agents).
    static func menu(pid: pid_t) -> [String: Any]? {
        guard let bar = menuBarElement(pid: pid) else { return nil }
        return walkMenu(bar)
    }

    /// Resolve a menu path (["File", "Save As…"]) to a leaf AXUIElement by
    /// walking the live tree — same algorithm as Hammerspoon's
    /// _findmenuitembypath but in Swift. Returns nil if any segment fails to
    /// match. Each step accepts either a direct title match on the current
    /// element's children, or — if the only child is an AXMenu — its
    /// grandchildren (unwrap the AXMenu the way menu() does).
    private static func resolveMenuPath(pid: pid_t, path: [String]) -> AXUIElement? {
        guard !path.isEmpty, let bar = menuBarElement(pid: pid) else { return nil }
        var current = bar
        var remaining = path
        var guardLoop = 5000
        while !remaining.isEmpty && guardLoop > 0 {
            guardLoop -= 1
            AXUIElementSetMessagingTimeout(current, 0.1)
            var kids = axChildren(current)
            if kids.count == 1,
               let role = axString(kids[0], kAXRoleAttribute),
               role == (kAXMenuRole as String) {
                kids = axChildren(kids[0])
            }
            let target = remaining.removeFirst()
            var matched: AXUIElement?
            for child in kids {
                if axString(child, kAXTitleAttribute) == target {
                    matched = child
                    break
                }
            }
            guard let found = matched else { return nil }
            current = found
        }
        return current
    }

    /// Look up a menu item by path. Returns a small dict
    /// `{title, role, enabled?, marked?, shortcut?}` matching the leaf shape
    /// from `menu()`. Returns nil if the path can't be resolved.
    static func findMenuItem(pid: pid_t, path: [String]) -> [String: Any]? {
        guard let el = resolveMenuPath(pid: pid, path: path) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        var out: [String: Any] = [:]
        if let t = axString(el, kAXTitleAttribute) { out["title"] = t }
        if let r = axString(el, kAXRoleAttribute)  { out["role"]  = r }
        if let e = axBool(el, kAXEnabledAttribute) { out["enabled"] = e }
        var markRef: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXMenuItemMarkCharAttribute as CFString, &markRef) == .success,
           markRef != nil {
            out["marked"] = true
        }
        return out
    }

    /// Press a menu item by path. Returns true if the path resolved and the
    /// AXPressAction succeeded — false otherwise. Mirrors hs.application's
    /// :selectMenuItem({"File", "Save"}).
    @discardableResult
    static func selectMenuItem(pid: pid_t, path: [String]) -> Bool {
        guard let el = resolveMenuPath(pid: pid, path: path) else { return false }
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    /// Windows owned by this pid that are not minimized. Filters Windows.all()
    /// (the same source-of-truth `sd.windows.all` returns) and drops
    /// minimized entries via WindowsByID.isMinimized — falling back to a
    /// direct AX query when the helper isn't available (defensive, since
    /// the curated AX surface lands alongside other R3 work).
    static func visibleWindows(pid: pid_t) -> [[String: Any]] {
        Windows.all().filter { entry in
            guard let p = entry["pid"] as? Int, pid_t(p) == pid else { return false }
            guard let id = entry["id"] as? Int else { return true }
            return !WindowsByID.isMinimized(windowID: CGWindowID(id))
        }
    }

    @discardableResult
    static func hide(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.hide()
    }

    @discardableResult
    static func unhide(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.unhide()
    }
}

final class AppsObserver: RefCountedObserver {
    static let shared = AppsObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let nc = NSWorkspace.shared.notificationCenter
        return installNotifications([
            (nc, NSWorkspace.didLaunchApplicationNotification),
            (nc, NSWorkspace.didTerminateApplicationNotification),
            (nc, NSWorkspace.didHideApplicationNotification),
            (nc, NSWorkspace.didUnhideApplicationNotification),
            (nc, NSWorkspace.didActivateApplicationNotification)
        ])
    }
}

// Cheap NSImage → PNG → base64 data-URL. Stacks use these in `<img src="">`
// directly, no extra fetch. For a launcher with 8 visible result rows the
// per-frame cost is one `icon(forFile:)` per row at startup; thereafter the
// browser caches the data URL. Future optimization: serve via sd://icon/<id>
// and skip the base64 round-trip — only worth it once a stack actually hurts.

enum Icons {
    static func forApp(bundleId: String, size: Int) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return dataURL(forIconAt: url, size: size)
    }

    static func forFile(path: String, size: Int) -> String? {
        let p = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: p) else { return nil }
        return dataURL(forIconAt: URL(fileURLWithPath: p), size: size)
    }

    private static func dataURL(forIconAt url: URL, size: Int) -> String? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        // Re-rasterize at the requested point size — Apple's icon may be a
        // multi-rep TIFF and we want a single PNG sized to taste.
        let target = NSImage(size: NSSize(width: size, height: size))
        target.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                  from: .zero, operation: .copy, fraction: 1.0)
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
