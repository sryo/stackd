import Foundation
import AppKit

// Tests for the `Apps` enum in Sources/DataSources/Apps.swift.
//
// Every static is NSWorkspace-, NSRunningApplication- or AX-coupled, so the
// suite sticks to what is safe on a live host:
//   - Negative branches of the bundleId- and pid-keyed verbs: a synthetic
//     bundle id / impossible pid short-circuits to `false` before anything
//     launches, terminates, hides or unhides.
//   - `running()` payload contract. NSWorkspace.runningApplications is an
//     ungated read, and a logged-in session always has bundled apps
//     (Finder, Dock), so the list is never empty.
//
// The AX surface (`menu`, `findMenuItem`, `selectMenuItem`, `*Window(s)`)
// is not covered: even with a bogus pid it goes through
// AXUIElementCreateApplication + AXUIElementCopyAttributeValue.

private let unknownBundleId = "com.stackd.tests.definitely.not.installed.xyz"

func registerAppsTests() {
    // MARK: - bundleId verbs — negative branches

    test("launch returns false for an empty or unregistered bundleId") {
        // urlForApplication returns nil → guard short-circuits before
        // openApplication, so nothing launches.
        try expectEqual(Apps.launch(bundleId: ""), false)
        try expectEqual(Apps.launch(bundleId: unknownBundleId), false)
    }

    test("focus returns false when no running app + no installed app matches") {
        // No running match → falls through to launch, which also misses.
        try expectEqual(Apps.focus(bundleId: unknownBundleId), false)
    }

    test("kill returns false when no running app matches the bundleId") {
        try expectEqual(Apps.kill(bundleId: unknownBundleId), false)
        try expectEqual(Apps.kill(bundleId: unknownBundleId, force: true), false)
    }

    test("hide(bundleId:) returns false when no running app matches") {
        try expectEqual(Apps.hide(bundleId: unknownBundleId), false)
    }

    // MARK: - pid verbs — deterministic negative inputs

    test("isFrontmost returns false for an impossible pid") {
        try expectEqual(Apps.isFrontmost(pid: -1), false)
    }

    test("pid verbs return false when no NSRunningApplication exists for the pid") {
        // JS sees a bool, never null, for unknown pids.
        try expectEqual(Apps.isHidden(pid: -1), false)
        try expectEqual(Apps.hide(pid: -1), false)
        try expectEqual(Apps.unhide(pid: -1), false)
    }

    // MARK: - running() — payload contract

    test("running rows carry the documented keys with the documented types") {
        // Every row must have a non-empty bundleId (apps without one are
        // filtered out — they can't be launched/focused by id) and one of
        // the three activationPolicy strings AppTimeout filters on.
        let allowed: Set<String> = ["regular", "accessory", "prohibited"]
        let entries = Apps.running()
        try expect(!entries.isEmpty, "expected ≥1 running app, got 0")
        for entry in entries {
            try expect(entry["pid"] is Int, "pid should be Int: \(entry)")
            guard let bundleId = entry["bundleId"] as? String else {
                throw Expectation(message: "entry missing bundleId: \(entry)")
            }
            try expect(!bundleId.isEmpty, "bundleId should be non-empty: \(entry)")
            try expect(entry["name"] is String, "name should be String: \(entry)")
            try expect(entry["active"] is Bool, "active should be Bool: \(entry)")
            try expect(entry["hidden"] is Bool, "hidden should be Bool: \(entry)")
            guard let policy = entry["activationPolicy"] as? String else {
                throw Expectation(message: "missing activationPolicy: \(entry)")
            }
            try expect(allowed.contains(policy),
                       "unexpected activationPolicy '\(policy)' (allowed: \(allowed))")
        }
    }

    test("running exposes bundleURL so consumers can tell .app apps from .xpc helpers") {
        // AppTimeout keys off the `.app` suffix to skip XPC service helpers
        // that transiently flip to .regular while presenting a panel.
        let entries = Apps.running()
        var sawBundleURL = false
        for entry in entries {
            guard let path = entry["bundleURL"] else { continue }
            guard let p = path as? String else {
                throw Expectation(message: "bundleURL should be String, got \(type(of: path))")
            }
            sawBundleURL = true
            try expect(p.hasPrefix("/"), "bundleURL should be an absolute path, got '\(p)'")
        }
        try expect(sawBundleURL, "no entry carried a bundleURL — field is missing from the payload")
    }
}
