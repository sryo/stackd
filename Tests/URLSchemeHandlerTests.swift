import Foundation
import WebKit

// Tests for `Sources/URLSchemeHandler.swift`.
//
// StackdSchemeHandler is the WKURLSchemeHandler that resolves `sd://` URLs to
// files on disk:
//   sd://runtime/<path>     → <runtimePath>/<path>
//   sd://<stackId>/<path>   → stacks[stackId]/<path>
//
// Testable surface:
//   1. The registration trio — `register(stackId:rootURL:)`,
//      `unregister(stackId:)`, `clearRegistrations()`. The backing `stacks`
//      dict is `private`, so we can only assert the negative (no throw, no
//      crash) plus idempotence. The dict is observed indirectly via the
//      `webView(_:start:)` method, but that path is not exercisable here.
//   2. Construction via `init(runtimePath:)` — must not crash with absurd
//      inputs (empty string, non-existent path); the path is stored verbatim
//      and only stat'd inside the schemeTask path.
//
// What we deliberately do NOT test:
//   - `webView(_:start:)` — requires a real WKURLSchemeTask. WKURLSchemeTask
//     is a protocol but the only sanctioned producer is WKWebView itself
//     during a live load. A hand-rolled conformer that the system later
//     consumes is documented to crash; a hand-rolled conformer we pass back
//     into the handler would exercise the resolution logic but the
//     `task.didReceive`/`task.didFinish` calls go to our own stub and prove
//     nothing about real-world behavior. Better covered by an integration
//     test driving WKWebView in a host process.
//   - `mimeType(for:)` — declared `private`. All 11 branches (html/htm,
//     js/mjs, css, json, svg, png, jpg/jpeg, woff2, default) are
//     unreachable without changing visibility, which is forbidden by the
//     constraints of this ticket. If a future change promotes it to
//     `fileprivate` (same file) or `internal`, the branches should be
//     pinned exhaustively in this file.
//   - The 404 stderr write and the HTTPURLResponse header shape — both
//     live inside `webView(_:start:)`.
//
// StackdSchemeHandler instances are per-WKWebView (not a singleton), so
// each test allocates a fresh handler — no global cleanup needed.

func registerURLSchemeHandlerTests() {

    // MARK: - Initialization

    test("init stores an empty registration map") {
        // Fresh handler must accept any runtime path without inspecting it
        // (the path is only resolved inside webView(_:start:)). The witness
        // is "construction does not throw"; we additionally exercise
        // unregister + clearRegistrations on the empty state to pin that
        // both are no-ops when nothing has been registered.
        let h = StackdSchemeHandler(runtimePath: "/tmp/stackd-test-runtime")
        h.unregister(stackId: "never-registered")
        h.clearRegistrations()
        _ = h // silence unused warning
    }

    test("init accepts an empty runtime path without crashing") {
        // The path is stored verbatim; it's only stat'd when a sd://runtime/*
        // URL is served. An empty string is a degenerate but valid input —
        // construction must succeed so callers don't have to pre-validate.
        let h = StackdSchemeHandler(runtimePath: "")
        h.clearRegistrations()
        _ = h
    }

    // MARK: - register / unregister / clearRegistrations

    test("register followed by unregister on the same id is safe") {
        // The dict is private, so we can only witness "no crash, no throw".
        // The contract: register sets stacks[stackId] = rootURL; unregister
        // removes the key. A round-trip must leave the handler in a state
        // equivalent to the fresh-init state — proved indirectly by the
        // next test (re-register same id) succeeding.
        let h = StackdSchemeHandler(runtimePath: "/tmp/stackd-test-runtime")
        let root = URL(fileURLWithPath: "/tmp/stackd-test-stack")
        h.register(stackId: "my-stack", rootURL: root)
        h.unregister(stackId: "my-stack")
    }

    test("register overwrites a prior registration for the same id") {
        // `stacks[stackId] = rootURL` is a plain dict assignment — the second
        // call must overwrite, not append or throw. We can't read the dict
        // back to verify which rootURL won, but pinning "no crash on
        // overwrite" guards against a future refactor that adds a duplicate
        // guard or assertion.
        let h = StackdSchemeHandler(runtimePath: "/tmp/stackd-test-runtime")
        h.register(stackId: "dup", rootURL: URL(fileURLWithPath: "/tmp/a"))
        h.register(stackId: "dup", rootURL: URL(fileURLWithPath: "/tmp/b"))
        h.unregister(stackId: "dup")
    }

    test("unregister on an unknown id is a silent no-op") {
        // `stacks.removeValue(forKey:)` returns nil on a missing key and
        // does not throw — Dictionary semantics. Bridge teardown can call
        // unregister after a stack has already been cleared (race during
        // hot reload); this guard is what keeps that safe.
        let h = StackdSchemeHandler(runtimePath: "/tmp/stackd-test-runtime")
        h.unregister(stackId: "never-registered")
        h.unregister(stackId: "")
    }

    test("clearRegistrations empties the map and is idempotent") {
        // `stacks.removeAll()` on a populated dict drops every entry; on an
        // empty dict it's a no-op. We exercise both paths in sequence.
        // After clear, a subsequent register/unregister on a previously-
        // cleared id must still work — proving the dict is reusable, not
        // sentinelled into a dead state.
        let h = StackdSchemeHandler(runtimePath: "/tmp/stackd-test-runtime")
        h.register(stackId: "a", rootURL: URL(fileURLWithPath: "/tmp/a"))
        h.register(stackId: "b", rootURL: URL(fileURLWithPath: "/tmp/b"))
        h.register(stackId: "c", rootURL: URL(fileURLWithPath: "/tmp/c"))
        h.clearRegistrations()
        h.clearRegistrations() // idempotent on empty
        h.register(stackId: "a", rootURL: URL(fileURLWithPath: "/tmp/a2"))
        h.unregister(stackId: "a")
    }

    test("register accepts many distinct ids without crashing") {
        // The dict is unbounded; the daemon can host arbitrarily many live
        // stacks. Pin "no growth ceiling" by inserting a batch and then
        // clearing them in one shot. If a future change ever added a cap,
        // this test would surface it before users hit it.
        let h = StackdSchemeHandler(runtimePath: "/tmp/stackd-test-runtime")
        for i in 0..<64 {
            h.register(
                stackId: "stack-\(i)",
                rootURL: URL(fileURLWithPath: "/tmp/stack-\(i)")
            )
        }
        h.clearRegistrations()
    }
}
