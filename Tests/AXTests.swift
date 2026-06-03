import AppKit
import ApplicationServices
import Foundation

// Characterization tests for Sources/DataSources/AX.swift.
//
// Scope: the parts of the AX wrapper that don't need TCC Accessibility
// permission or a live AX tree — namely the per-Bridge HandleStore and the
// process-wide AXObserverPool's diagnostic counter. Element creation
// (`application(pid:store:)`, `systemWide(store:)`) is testable too: those
// AXUIElementCreate* calls don't probe AX, they just allocate refs and mint.
//
// Skipped (would need access changes or AX/TCC):
// - marshal(_:store:) and toCFType(_:store:) — fileprivate.
// - focusedElement(), focusedElementHandle(store:),
//   focusedElementSystemWideHandle(store:) — frontmost app + AX trust.
// - attributeNames/attribute/children/parent/role/setAttribute/performAction —
//   require AXUIElementCopy* against a real element, which needs TCC.
// - AXAppObserver init — succeeds without TCC but installs a CFRunLoopSource
//   on the main runloop, which the harness runs off-main.

func registerAXTests() {
    test("AX.HandleStore.mint returns sequential ids starting at 1") {
        let store = AX.HandleStore()
        let el = AXUIElementCreateSystemWide()
        let h1 = store.mint(el)
        let h2 = store.mint(el)
        let h3 = store.mint(el)
        try expectEqual(h1, 1)
        try expectEqual(h2, 2)
        try expectEqual(h3, 3)
    }

    test("AX.HandleStore.get returns the element for a live handle") {
        let store = AX.HandleStore()
        let el = AXUIElementCreateSystemWide()
        let h = store.mint(el)
        try expect(store.get(h) != nil, "live handle should resolve")
        try expect(store.get(9999) == nil, "unknown handle should be nil")
    }

    test("AX.HandleStore.release frees the slot and is idempotent-by-bool") {
        let store = AX.HandleStore()
        let h = store.mint(AXUIElementCreateSystemWide())
        try expectEqual(store.release(h), true)
        try expect(store.get(h) == nil, "released handle should not resolve")
        try expectEqual(store.release(h), false)
    }

    test("AX.HandleStore.releaseAll clears every handle") {
        let store = AX.HandleStore()
        _ = store.mint(AXUIElementCreateSystemWide())
        _ = store.mint(AXUIElementCreateSystemWide())
        let stray = store.mint(AXUIElementCreateSystemWide())
        store.releaseAll()
        try expect(store.get(stray) == nil, "releaseAll should drop all slots")
    }

    test("AX.HandleStore handle ids keep advancing after release") {
        // Sanity that the `next` cursor doesn't recycle ids — JS stacks rely on
        // released handles staying dead, not getting reassigned to new refs.
        let store = AX.HandleStore()
        let h1 = store.mint(AXUIElementCreateSystemWide())
        _ = store.release(h1)
        let h2 = store.mint(AXUIElementCreateSystemWide())
        try expect(h2 > h1, "minted id should be greater than any prior id")
    }

    test("AX.application(pid:store:) mints a handle for the current process") {
        // AXUIElementCreateApplication doesn't probe AX permission — it just
        // wraps the pid. Safe to call without TCC; verifies the mint path.
        let store = AX.HandleStore()
        let h = AX.application(pid: ProcessInfo.processInfo.processIdentifier, store: store)
        try expect(h >= 1, "minted handle should be positive")
        try expect(store.get(h) != nil, "minted handle should resolve in the store")
    }

    test("AX.systemWide(store:) mints a handle for the systemwide element") {
        let store = AX.HandleStore()
        let h = AX.systemWide(store: store)
        try expect(h >= 1, "minted handle should be positive")
        try expect(store.get(h) != nil, "minted handle should resolve in the store")
    }

    test("AX.focusedElementSystemWideHandle returns nil-or-valid (TCC-gated, never crashes)") {
        // Without Accessibility permission the AXUIElementCopyAttributeValue
        // call returns an error and we yield nil. With permission it mints
        // a handle. Both outcomes are valid; what we're testing is that the
        // function doesn't crash and that any returned handle is well-formed.
        let store = AX.HandleStore()
        let h = AX.focusedElementSystemWideHandle(store: store)
        if let h = h {
            try expect(h >= 1, "minted handle should be positive")
            try expect(store.get(h) != nil, "minted handle should resolve in the store")
        }
        // nil is the expected outcome in the test harness, which doesn't
        // have Accessibility permission — pass-through.
    }

    test("AXObserverPool.liveObserverCount is non-negative at rest") {
        // The pool is process-wide and may legitimately be non-zero if another
        // test or the host process installed an observer. Just assert the
        // invariant: counts are never negative.
        try expect(AXObserverPool.liveObserverCount() >= 0, "pool count must be non-negative")
    }
}
