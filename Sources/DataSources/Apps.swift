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
// observer) lives in the Window*.swift files — they share the AX + CGWindowList machinery.

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
            // Bundle path lets consumers tell real `.app` apps from XPC service
            // helpers (`.xpc` bundles inside frameworks). Those services flip to
            // .regular while presenting a panel (Open/Save, Quick Look), so the
            // policy field alone can't filter them — AppTimeout keys off the
            // `.app` suffix to avoid monitoring/killing them.
            if let burl = app.bundleURL {
                entry["bundleURL"] = burl.path
            }
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

    /// `.activateIgnoringOtherApps` is load-bearing: stackd is `.accessory` +
    /// `.nonactivatingPanel` and never frontmost, so without it AppKit silently
    /// no-ops the activation.
    @discardableResult
    static func focus(bundleId: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            return app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
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
    // messaging timeout at 100ms (same as the Window*.swift files) so an unresponsive
    // app can't stall the daemon.

    // Element keyed by its kAXMenuBarAttribute (the app's AXMenuBar). Apps
    // that don't surface a menu bar (background helpers, agents) return nil.
    private static func menuBarElement(pid: pid_t) -> AXUIElement? {
        AX.element(of: AX.appElement(pid: pid, timeout: 0.1), kAXMenuBarAttribute)
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
        // 100ms was too aggressive — apps with large/dynamic menubars
        // (Xcode, Safari with many extensions, anything driving NSMenu via
        // delegate-populated lazy sections) silently dropped items because
        // individual attribute reads on a busy main thread can take longer
        // than that. 1s gives the slow path room to complete while still
        // bounding worst-case hang if an app is fully wedged. Net effect
        // on happy path: invisible (AX responds in <10ms when responsive).
        AXUIElementSetMessagingTimeout(el, 1.0)
        var out: [String: Any] = [:]
        if let title = AX.string(of: el, kAXTitleAttribute) { out["title"] = title }
        if let role  = AX.string(of: el, kAXRoleAttribute)  { out["role"]  = role }
        if let enabled = AX.bool(of: el, kAXEnabledAttribute) { out["enabled"] = enabled }
        // AXMenuItemMarkChar is unset (kAXErrorNoValue) when the item isn't
        // ticked; presence of any value means marked. We surface this as a
        // bool so JS consumers don't have to special-case the ✓ character.
        if AX.hasValue(el, kAXMenuItemMarkCharAttribute) {
            out["marked"] = true
        }
        // Keyboard shortcut as a short string ("⌘S"). cmdChar is the key
        // glyph; cmdModifiers is the modifier mask (kAXMenuItemModifierNoCommand
        // means no shortcut). Best-effort — apps without shortcut attributes
        // simply omit the key.
        if let cmdChar = AX.string(of: el, kAXMenuItemCmdCharAttribute), !cmdChar.isEmpty {
            let mods = AX.int(of: el, kAXMenuItemCmdModifiersAttribute) ?? 0
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
        let kids = AX.children(of: el)
        if !kids.isEmpty {
            var effective = kids
            if kids.count == 1,
               let firstRole = AX.string(of: kids[0], kAXRoleAttribute),
               firstRole == (kAXMenuRole as String) {
                effective = AX.children(of: kids[0])
            }
            // Only emit `children` when the element actually has menu structure.
            // Leaves (AXMenuItem with no submenu) keep the key absent.
            if !effective.isEmpty || (out["role"] as? String) == (kAXMenuBarRole as String) {
                out["children"] = effective.map { walkMenu($0) }
            }
        }
        return out
    }

    /// Count every titled leaf in the walked tree so the stderr log can
    /// quantify what the AX walk produced — when a palette shows only a few
    /// items, this tells us whether the problem is at the Swift/AX boundary
    /// or in the JS flattener.
    private static func countLeaves(_ node: [String: Any]) -> Int {
        if let kids = node["children"] as? [[String: Any]], !kids.isEmpty {
            return kids.reduce(0) { $0 + countLeaves($1) }
        }
        // A node with no children-array (or empty) is a leaf if it has a
        // non-empty title. Wrappers (AXMenu containers with no title) get
        // 0 here, which mirrors what collectMenuLeaves on the JS side does.
        if let t = node["title"] as? String, !t.isEmpty { return 1 }
        return 0
    }

    /// Full menu-bar tree as a nested dict. Root is the AXMenuBar (carries
    /// `children` of top-level menus). Returns nil if the app has no menu bar
    /// (background helpers, agents).
    static func menu(pid: pid_t) -> [String: Any]? {
        guard let bar = menuBarElement(pid: pid) else { return nil }
        // Some apps (notably Terminal pre-warmup) won't populate AXMenu
        // children attribute until they're queried with the "enhanced UI"
        // hint set — same trick Hammerspoon, VoiceOver and Shortcuts use
        // to walk a full menubar without simulating a click. Set on the
        // app element, not per menu item. Restore after walking so we
        // don't permanently mutate the target app's AX behavior (some
        // apps lay out controls differently when this is on).
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        let tree = AXEnhancedUI.scope(appEl, want: true, prior: AXEnhancedUI.read(appEl)) {
            walkMenu(bar)
        }
        // Telemetry: log the walk size to stderr. When a palette shows only
        // a few menu items, this tells us up-front whether the AX walk
        // produced 200 items (problem is downstream) or 5 (problem is here —
        // likely the app didn't respond to the AXEnhancedUserInterface hint).
        log("apps.menu(pid:\(pid)) — walked \(countLeaves(tree)) leaf(s)")
        return tree
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
            var kids = AX.children(of: current)
            if kids.count == 1,
               let role = AX.string(of: kids[0], kAXRoleAttribute),
               role == (kAXMenuRole as String) {
                kids = AX.children(of: kids[0])
            }
            let target = remaining.removeFirst()
            var matched: AXUIElement?
            for child in kids {
                if AX.string(of: child, kAXTitleAttribute) == target {
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
        if let t = AX.string(of: el, kAXTitleAttribute) { out["title"] = t }
        if let r = AX.string(of: el, kAXRoleAttribute)  { out["role"]  = r }
        if let e = AX.bool(of: el, kAXEnabledAttribute) { out["enabled"] = e }
        if AX.hasValue(el, kAXMenuItemMarkCharAttribute) {
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

    // MARK: - Per-pid window-set surface (AX)
    //
    // Completes the curated window-set surface around `visibleWindows(pid)`.
    // Each method walks the app's AX tree, maps AXUIElement → CGWindowID via
    // the AX shim in Windows.swift, and returns ids only — JS chains into
    // `sd.windows.byId.*` for any per-window action it wants. AX messaging
    // timeout capped at 100ms (same as `menu`/`visibleWindows`) so an
    // unresponsive app can't stall the daemon.

    /// CGWindowID of the AX focused window for `pid`, or nil if the app has
    /// no focused window (background-only, all minimized, etc.) or the SPI
    /// shim is unavailable. Mirrors hs.application:focusedWindow.
    static func focusedWindow(pid: pid_t) -> Int? {
        windowID(pid: pid, attribute: kAXFocusedWindowAttribute)
    }

    /// CGWindowID of the AX main window for `pid`, or nil. The main window
    /// is the app's primary document/UI window; it may or may not be the
    /// focused window (e.g. a focused inspector/palette atop a main doc).
    /// Mirrors hs.application:mainWindow.
    static func mainWindow(pid: pid_t) -> Int? {
        windowID(pid: pid, attribute: kAXMainWindowAttribute)
    }

    /// CGWindowID of the window element `attribute` names on the app, nil
    /// when the app has none or the SPI shim is unavailable.
    private static func windowID(pid: pid_t, attribute: String) -> Int? {
        guard let getWindow = AXShim.getWindow,
              let win = AX.element(of: AX.appElement(pid: pid, timeout: 0.1), attribute) else { return nil }
        var wid: CGWindowID = 0
        guard getWindow(win, &wid) == .success else { return nil }
        return Int(wid)
    }

    /// All CGWindowIDs owned by `pid` as reported by AX (`kAXWindows`).
    /// Includes minimized windows. Empty array if the app has none or the
    /// SPI shim is unavailable. Mirrors hs.application:allWindows but
    /// returns ids only.
    static func allWindows(pid: pid_t) -> [Int] {
        guard let getWindow = AXShim.getWindow,
              let arr = AX.elements(of: AX.appElement(pid: pid, timeout: 0.1), kAXWindowsAttribute) else { return [] }
        var out: [Int] = []
        out.reserveCapacity(arr.count)
        for el in arr {
            var wid: CGWindowID = 0
            if getWindow(el, &wid) == .success {
                out.append(Int(wid))
            }
        }
        return out
    }

    // MARK: - Per-pid app state (AppKit)
    //
    // Cheap NSWorkspace / NSRunningApplication queries — no AX gate, no
    // main-hop required (dispatched via `.sync` in Bridge). Mirrors
    // hs.application:isFrontmost / :isHidden.

    static func isFrontmost(pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    static func isHidden(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
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
        return ImageEncoding.pngDataURL(size: NSSize(width: size, height: size)) {
            icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                      from: .zero, operation: .copy, fraction: 1.0)
        }
    }
}

/// Scoped toggle of an app's AXEnhancedUserInterface. The attribute is
/// app-wide: assistive tools (VoiceOver, some window managers) turn it on,
/// menu walks need it on for apps that only populate menus then, and apps
/// with it on animate their own frame changes, so AX frame writes land
/// late and step-wise unless it is off for the write. Every scope restores
/// what it found.
enum AXEnhancedUI {
    static let attribute = "AXEnhancedUserInterface" as CFString

    struct Plan: Equatable {
        /// Value to set before the body; nil = leave as is.
        let set: Bool?
        /// Value to restore after the body; nil = nothing to restore.
        let restore: Bool?
    }

    /// `prior` nil = the app doesn't expose the attribute, which behaves
    /// as off.
    static func plan(prior: Bool?, want: Bool) -> Plan {
        let current = prior ?? false
        if current == want { return Plan(set: nil, restore: nil) }
        return Plan(set: want, restore: current)
    }

    /// Current value, nil when the app doesn't expose it.
    static func read(_ appEl: AXUIElement) -> Bool? {
        AX.bool(of: appEl, attribute as String)
    }

    /// Run `body` with the attribute at `want`, then put back what `prior`
    /// says was there. Thread-agnostic.
    static func scope<T>(_ appEl: AXUIElement, want: Bool, prior: Bool?, _ body: () -> T) -> T {
        let p = plan(prior: prior, want: want)
        if let v = p.set { AXUIElementSetAttributeValue(appEl, attribute, v ? kCFBooleanTrue : kCFBooleanFalse) }
        defer {
            if let r = p.restore { AXUIElementSetAttributeValue(appEl, attribute, r ? kCFBooleanTrue : kCFBooleanFalse) }
        }
        return body()
    }
}
