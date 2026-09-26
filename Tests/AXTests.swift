import AppKit
import ApplicationServices
import Foundation

// Tests for Sources/DataSources/AX.swift that need neither Accessibility
// permission nor a live AX tree: the per-Bridge HandleStore, element-handle
// minting (AXUIElementCreate* only allocates, it doesn't query AX), and
// AXAppObserver's notification routing rule. Attribute reads/writes,
// actions and focused-element lookups need TCC and a real target.

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
        let handles = (0..<3).map { _ in store.mint(AXUIElementCreateSystemWide()) }
        store.releaseAll()
        for h in handles {
            try expect(store.get(h) == nil, "releaseAll should drop handle \(h)")
        }
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

    test("AXAppObserver.routes — app-scope broadcasts, element-scope matches only itself") {
        // One window's miniaturize must not fan out to every window's
        // closure: element-scoped subscriptions fire only for their own
        // element; app-element subscriptions receive all (their callback
        // element is the affected child, e.g. kAXWindowCreated's window).
        let app = AXUIElementCreateApplication(getpid())
        let winA = AXUIElementCreateApplication(1)      // distinct stand-in elements —
        let winB = AXUIElementCreateSystemWide()        // CFEqual-distinct from `app`
        try expect(AXAppObserver.routes(target: app, appElement: app, affected: winA),
                   "app-scoped subscription must receive child notifications")
        try expect(AXAppObserver.routes(target: winA, appElement: app, affected: winA),
                   "element-scoped subscription must receive its own element")
        try expect(!AXAppObserver.routes(target: winB, appElement: app, affected: winA),
                   "element-scoped subscription must NOT receive another element's event")
    }
}
