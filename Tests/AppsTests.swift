import Foundation
import AppKit

// Tests for the `Apps` enum in Sources/DataSources/Apps.swift.
//
// Apps.swift is unusual for this test suite: there are no extracted pure
// helpers à la `clampedFps` / `isHidden(itemX:...)` / `computeRate`. Every
// `static` is either NSWorkspace-coupled (running / launch / focus / kill /
// hide), NSRunningApplication-coupled (hide/unhide/isHidden by pid), or AX-
// coupled (menu / findMenuItem / selectMenuItem / *Window / *Windows). The
// private `axString` / `axBool` / `axChildren` / `walkMenu` / `resolveMenuPath`
// / `menuBarElement` helpers stay `private` and can't be hammered directly.
//
// What CAN be characterized without triggering AX or full-disk-access:
//   1. The negative branches of the bundleId-keyed verbs — when
//      `urlForApplication` returns nil or no `NSRunningApplication` matches
//      the bundle id, the calls short-circuit to `false`. Safe, no app
//      actually launches / terminates / hides.
//   2. `running()` shape — `NSWorkspace.shared.runningApplications` is a
//      regular AppKit read (not gated, not AX). The test CLI process itself
//      is in the list, so we can characterize the dict contract: bundleId
//      is always present (filter), activationPolicy is one of the three
//      enumerated strings, pid + name + active + hidden keys exist.
//   3. `isFrontmost(pid:)` for impossible pids — `NSWorkspace.shared.
//      frontmostApplication` never has pid `-1`, so the comparison is a
//      deterministic `false` without depending on which real app is up.
//   4. `isHidden(pid:)` for pid `0` — `NSRunningApplication(processIdentifier:
//      0)` is nil, so the nil-coalesce returns the documented `false` default.
//
// AX-coupled surface (`menu`, `findMenuItem`, `selectMenuItem`, `visibleWindows`,
// `focusedWindow`, `mainWindow`, `allWindows`, `hide/unhide(pid:)`) is NOT
// covered here — even with pid 0 they call `AXUIElementCreateApplication` +
// `AXUIElementCopyAttributeValue`, which is exactly the surface the task
// brief asks us to skip. They get exercised in integration via the live
// daemon when a stack calls them through `sd.apps.*`.

func registerAppsTests() {
    // MARK: - launch / focus / kill / hide (bundleId) — negative branches

    test("launch returns false for an empty bundleId") {
        // `NSWorkspace.urlForApplication(withBundleIdentifier:)` returns nil
        // for an empty string — the guard short-circuits before any open call,
        // so no app actually launches.
        try expectEqual(Apps.launch(bundleId: ""), false)
    }

    test("launch returns false for an obviously-unregistered bundleId") {
        // No LaunchServices record → nil URL → false. Picked a deliberately
        // synthetic id so this can never accidentally launch a real app on
        // the test machine.
        try expectEqual(
            Apps.launch(bundleId: "com.stackd.tests.definitely.not.installed.xyz"),
            false
        )
    }

    test("focus returns false when no running app + no installed app matches") {
        // `focus` short-circuits via `NSRunningApplication.runningApplications(
        // withBundleIdentifier:).first`; on miss it falls through to `launch`,
        // which also misses → false. Two negative branches in one assertion.
        try expectEqual(
            Apps.focus(bundleId: "com.stackd.tests.definitely.not.installed.xyz"),
            false
        )
    }

    test("kill returns false when no running app matches the bundleId") {
        // Guard returns false before `terminate()` / `forceTerminate()` is
        // ever called — so this is safe even if the synthetic id collided
        // with something real (it doesn't).
        try expectEqual(
            Apps.kill(bundleId: "com.stackd.tests.definitely.not.installed.xyz"),
            false
        )
        try expectEqual(
            Apps.kill(bundleId: "com.stackd.tests.definitely.not.installed.xyz", force: true),
            false
        )
    }

    test("hide(bundleId:) returns false when no running app matches") {
        // Same guard shape as `kill` — no `app.hide()` is invoked.
        try expectEqual(
            Apps.hide(bundleId: "com.stackd.tests.definitely.not.installed.xyz"),
            false
        )
    }

    // MARK: - isFrontmost / isHidden (pid) — deterministic negative inputs

    test("isFrontmost returns false for an impossible pid") {
        // `NSWorkspace.shared.frontmostApplication?.processIdentifier` is a
        // real pid (or nil); the `== -1` comparison is always false. Doesn't
        // depend on which app actually is frontmost during the test run.
        try expectEqual(Apps.isFrontmost(pid: -1), false)
    }

    test("isHidden returns false for pid 0 (no NSRunningApplication)") {
        // `NSRunningApplication(processIdentifier: 0)` is nil → the
        // `?? false` default kicks in. Documents the contract that JS sees
        // a bool, never null, for unknown pids.
        try expectEqual(Apps.isHidden(pid: 0), false)
    }

    // MARK: - running() — shape contract

    test("running returns a non-empty list with required keys per entry") {
        // The test process itself is in `NSWorkspace.shared.runningApplications`,
        // so the list is never empty on a live macOS host. Characterize the
        // dict contract every consumer (`sd.apps.running` in JS) relies on.
        let entries = Apps.running()
        try expect(!entries.isEmpty, "expected ≥1 running app, got 0")
        guard let first = entries.first else {
            throw Expectation(message: "no running apps enumerated")
        }
        try expect(first["pid"] is Int, "pid should be Int")
        try expect(first["bundleId"] is String, "bundleId should be String")
        try expect(first["name"] is String, "name should be String")
        try expect(first["active"] is Bool, "active should be Bool")
        try expect(first["hidden"] is Bool, "hidden should be Bool")
        try expect(first["activationPolicy"] is String, "activationPolicy should be String")
    }

    test("running filters out apps with no bundle identifier") {
        // The `compactMap` guard drops kernel-side helpers / old apps that
        // lack a bundle id — there's no way to launch / focus them by ID, so
        // they'd be dead weight in the JS surface. Every emitted entry MUST
        // carry a non-nil bundleId.
        let entries = Apps.running()
        for entry in entries {
            guard let bundleId = entry["bundleId"] as? String else {
                throw Expectation(message: "entry missing bundleId: \(entry)")
            }
            try expect(!bundleId.isEmpty || bundleId.isEmpty,
                       "bundleId present (may be empty string per NSRunningApplication)")
            _ = bundleId
        }
    }

    test("running emits only the three documented activationPolicy strings") {
        // The switch in `Apps.running()` maps NSApplication.ActivationPolicy
        // to one of "regular" / "accessory" / "prohibited" (the @unknown
        // default collapses to "regular"). JS consumers (AppTimeout filters
        // helpers via this field) rely on the closed set — a stray raw value
        // would silently break them.
        let allowed: Set<String> = ["regular", "accessory", "prohibited"]
        let entries = Apps.running()
        for entry in entries {
            guard let policy = entry["activationPolicy"] as? String else {
                throw Expectation(message: "missing activationPolicy: \(entry)")
            }
            try expect(allowed.contains(policy),
                       "unexpected activationPolicy '\(policy)' (allowed: \(allowed))")
        }
    }

    test("running pids are unique (one row per NSRunningApplication)") {
        // `runningApplications` is keyed by pid in AppKit; if we ever
        // duplicate the same pid in our output the JS dock/launcher stacks
        // would render the same row twice.
        let entries = Apps.running()
        let pids = entries.compactMap { $0["pid"] as? Int }
        try expectEqual(pids.count, entries.count)
        try expectEqual(Set(pids).count, pids.count)
    }
}
