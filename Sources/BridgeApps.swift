import Foundation

/// `sd.apps.*` primitives — bundleId-keyed lifecycle ops + per-pid
/// AX-walking readers. Permission: `"apps"`.
///
/// Split between `.sync` (NSWorkspace / NSRunningApplication — thread-safe
/// AppKit reads), `.ax` (AX traffic that must hop to main to avoid
/// cross-thread deadlocks). hide / unhide come in two flavors: the
/// bundleId variant (NSWorkspace lookup, `.sync`) and the per-pid
/// variant (NSRunningApplication on the matching pid, `.ax`-routed
/// because the menu / window walks share the same hop).
extension Bridge {
    static func appsPrimitives() -> [Primitive] { [
        // Apps — Bool side-effect ops, deny → false.
        .sync("apps.launch", permission: "apps", denyValue: false) { body in Apps.launch(bundleId: body["bundleId"] as? String ?? "") },
        .sync("apps.focus",  permission: "apps", denyValue: false) { body in Apps.focus( bundleId: body["bundleId"] as? String ?? "") },
        .sync("apps.kill",   permission: "apps", denyValue: false) { body in Apps.kill(  bundleId: body["bundleId"] as? String ?? "", force: body["force"] as? Bool ?? false) },
        .sync("apps.hide",   permission: "apps", denyValue: false) { body in Apps.hide(  bundleId: body["bundleId"] as? String ?? "") },

        // Curated AX readers on a pid (mirrors hs.application's menu /
        // findMenuItem / selectMenuItem / visibleWindows / hide / unhide).
        // All hop to main via `.ax` because they walk AXUIElement trees.
        // hide / unhide are pid-specific; the JS surface routes
        // sd.apps.hide(pid) → hideByPid.
        .ax("apps.menu", permission: "apps") { _, body in
            Apps.menu(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        .ax("apps.findMenuItem", permission: "apps") { _, body in
            Apps.findMenuItem(
                pid: pid_t((body["pid"] as? Int) ?? 0),
                path: (body["path"] as? [String]) ?? []
            )
        },
        .ax("apps.selectMenuItem", permission: "apps", denyValue: false) { _, body in
            Apps.selectMenuItem(
                pid: pid_t((body["pid"] as? Int) ?? 0),
                path: (body["path"] as? [String]) ?? []
            )
        },
        .ax("apps.visibleWindows", permission: "apps", denyValue: [[String: Any]]()) { _, body in
            Apps.visibleWindows(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        .ax("apps.hideByPid", permission: "apps", denyValue: false) { _, body in
            Apps.hide(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        .ax("apps.unhideByPid", permission: "apps", denyValue: false) { _, body in
            Apps.unhide(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        // Per-pid window-set readers. Return CGWindowID(s); JS chains into
        // sd.windows.byId.* from there. `.ax` (main-hop) because they walk
        // the AX tree.
        .ax("apps.focusedWindow", permission: "apps") { _, body in
            Apps.focusedWindow(pid: pid_t((body["pid"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        .ax("apps.mainWindow", permission: "apps") { _, body in
            Apps.mainWindow(pid: pid_t((body["pid"] as? Int) ?? 0)) as Any? ?? NSNull()
        },
        .ax("apps.allWindows", permission: "apps", denyValue: [Int]()) { _, body in
            Apps.allWindows(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        // Per-pid app state. Pure AppKit — `.sync` (no main-hop) because
        // NSWorkspace.frontmostApplication / NSRunningApplication.isHidden
        // are thread-safe AppKit reads with no AX gate.
        .sync("apps.isFrontmost", permission: "apps", denyValue: false) { body in
            Apps.isFrontmost(pid: pid_t((body["pid"] as? Int) ?? 0))
        },
        .sync("apps.isHidden", permission: "apps", denyValue: false) { body in
            Apps.isHidden(pid: pid_t((body["pid"] as? Int) ?? 0))
        }
    ] }
}
