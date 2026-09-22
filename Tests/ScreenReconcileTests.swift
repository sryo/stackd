import Foundation
import CoreGraphics

// Tests for `ScreenReconcile` in `Sources/StackHost.swift` — what a display
// change means for one stack: keep its instances running and just move them
// (same displays, new geometry), or reload only that stack (its set of
// target displays changed).

func registerScreenReconcileTests() {
    test("ScreenReconcile keeps a single-display stack when its display survives") {
        let plan = ScreenReconcile.plan(id: "windowscape",
                                        instances: ["windowscape": 1],
                                        targets: [(0, 1)])
        try expect(plan == .relayout([.init(key: "windowscape", screenIndex: 0)]))
    }

    test("ScreenReconcile keeps a primary stack when a second display is added") {
        // display:"primary" still resolves to display 1 — no reload, so the
        // stack keeps its in-memory state (windowscape's learned minimums).
        let plan = ScreenReconcile.plan(id: "windowscape",
                                        instances: ["windowscape": 1],
                                        targets: [(0, 1)])
        try expect(plan == .relayout([.init(key: "windowscape", screenIndex: 0)]))
    }

    test("ScreenReconcile reloads a per-display stack when a display is added") {
        // 1 → 2 displays changes the instance keys (id → id@0, id@1).
        let plan = ScreenReconcile.plan(id: "bar",
                                        instances: ["bar": 1],
                                        targets: [(0, 1), (1, 2)])
        try expect(plan == .reload)
    }

    test("ScreenReconcile reloads a per-display stack when a display is removed") {
        let plan = ScreenReconcile.plan(id: "bar",
                                        instances: ["bar@0": 1, "bar@1": 2],
                                        targets: [(0, 1)])
        try expect(plan == .reload)
    }

    test("ScreenReconcile relays out every instance when the display set is unchanged") {
        let plan = ScreenReconcile.plan(id: "bar",
                                        instances: ["bar@0": 1, "bar@1": 2],
                                        targets: [(0, 1), (1, 2)])
        try expect(plan == .relayout([.init(key: "bar@0", screenIndex: 0),
                                      .init(key: "bar@1", screenIndex: 1)]))
    }

    test("ScreenReconcile reloads when an instance's display was replaced") {
        // Same key, different physical display (primary moved to the external).
        let plan = ScreenReconcile.plan(id: "windowscape",
                                        instances: ["windowscape": 1],
                                        targets: [(0, 2)])
        try expect(plan == .reload)
    }

    test("ScreenReconcile unloads a stack whose display is gone") {
        let plan = ScreenReconcile.plan(id: "pinned", instances: ["pinned": 2], targets: [])
        try expect(plan == .unload)
    }
}
