import Foundation

// Tests for `OverlayTickArm` in `Sources/DataSources/OverlayPolicy.swift` — when a
// window-tracking overlay runs its per-vsync tick. Events about the target
// arm it; it keeps itself armed while the target's frame or visibility keeps
// changing, and disarms after a short quiet spell. A slow backstop covers
// targets whose apps post no events.

func registerOverlayTickArmTests() {
    let idle = OverlayTickArm.idle

    test("OverlayTickArm: starts disarmed with the backstop running") {
        let a = OverlayTickArm()
        try expect(!a.armed)
        try expect(a.wantsBackstop(now: 0))
    }

    test("OverlayTickArm: the first arm reports it, re-arming while armed does not") {
        var a = OverlayTickArm()
        try expect(a.arm(now: 0), "caller subscribes to vsync on this edge")
        try expect(!a.arm(now: 0.01), "already subscribed")
        try expect(a.armed)
        try expect(!a.wantsBackstop(now: 0.01), "vsync ticks cover it while armed")
    }

    test("OverlayTickArm: stays armed while the frame keeps changing") {
        var a = OverlayTickArm()
        _ = a.arm(now: 0)
        var t = 0.0
        for _ in 0..<30 {
            t += 0.016
            try expect(a.afterTick(now: t, changed: true, busy: { false }))
        }
    }

    test("OverlayTickArm: disarms after the idle spell with no change") {
        var a = OverlayTickArm()
        _ = a.arm(now: 0)
        try expect(a.afterTick(now: 0.05, changed: true, busy: { false }))
        try expect(a.afterTick(now: 0.05 + idle - 0.01, changed: false, busy: { false }))
        try expect(!a.afterTick(now: 0.05 + idle + 0.01, changed: false, busy: { false }))
        try expect(!a.armed)
        try expect(a.wantsBackstop(now: 1))
    }

    test("OverlayTickArm: an event with no follow-up change still disarms") {
        var a = OverlayTickArm()
        _ = a.arm(now: 1)
        try expect(!a.afterTick(now: 1 + idle + 0.001, changed: false, busy: { false }))
    }

    test("OverlayTickArm: a longer hold keeps ticking through an animation with no change yet") {
        // Minimize / hide / space switch: the target's visibility flips at the
        // end of a system animation, well after the event.
        var a = OverlayTickArm()
        _ = a.arm(now: 0, hold: 0.6)
        try expect(a.afterTick(now: 0.5, changed: false, busy: { false }))
        try expect(!a.afterTick(now: 0.61, changed: false, busy: { false }))
    }

    test("OverlayTickArm: a short arm never cuts an earlier longer hold") {
        var a = OverlayTickArm()
        _ = a.arm(now: 0, hold: 0.6)
        _ = a.arm(now: 0.1)
        try expect(a.afterTick(now: 0.5, changed: false, busy: { false }))
    }

    test("OverlayTickArm: a held button keeps it armed through a paused drag") {
        // A user pausing mid-drag posts no events; resuming must not wait for
        // the next coalesced AX bang to re-arm.
        var a = OverlayTickArm()
        _ = a.arm(now: 0)
        try expect(a.afterTick(now: 0.5, changed: false, busy: { true }))
        try expect(a.afterTick(now: 0.5 + idle - 0.01, changed: false, busy: { false }),
                   "release starts a fresh idle spell")
        try expect(!a.afterTick(now: 0.5 + idle + 0.01, changed: false, busy: { false }))
    }

    test("OverlayTickArm: doesn't query the button while inside the idle spell") {
        var a = OverlayTickArm()
        _ = a.arm(now: 0)
        var queried = false
        _ = a.afterTick(now: 0.01, changed: false, busy: { queried = true; return true })
        try expect(!queried)
    }

    test("OverlayTickArm: re-arms after disarming") {
        var a = OverlayTickArm()
        _ = a.arm(now: 0)
        _ = a.afterTick(now: 1, changed: false, busy: { false })
        try expect(a.arm(now: 2))
    }

    test("OverlayTickArm: backstop interval is a slow safety net, not a poll") {
        try expect(OverlayTickArm.backstopInterval >= 0.25)
        try expect(OverlayTickArm.backstopInterval <= 1)
    }

    test("OverlayHandle backstop timer: repeats every backstopInterval and lets the system coalesce its wakeups") {
        let timer = OverlayHandle.backstopTimer {}
        defer { timer.invalidate() }
        try expectEqual(timer.timeInterval, OverlayTickArm.backstopInterval)
        try expect(abs(timer.tolerance - 0.1) < 0.001, "tolerance \(timer.tolerance)")
    }

    test("OverlayArmEvents: frame and z-order bangs arm for the idle spell") {
        for name in ["sd.window.moved", "sd.window.resized", "sd.window.reordered",
                     "sd.window.focused", "sd.window.focusedByMouse"] {
            try expectEqual(OverlayArmEvents.hold(forBang: name), OverlayTickArm.idle, name)
        }
    }

    test("OverlayArmEvents: visibility bangs hold through the system animation") {
        for name in ["sd.window.minimized", "sd.window.deminimized", "sd.window.destroyed"] {
            try expectEqual(OverlayArmEvents.hold(forBang: name), OverlayTickArm.visibilityHold, name)
        }
        try expect(OverlayTickArm.visibilityHold > OverlayTickArm.idle)
    }

    test("OverlayTickArm: stays armed while the target animates, however long the animation") {
        // Deminimize: the panel stays hidden (no change) for the whole genie
        // and must come back on the frame the warp ends, not at the next
        // backstop tick.
        var a = OverlayTickArm()
        _ = a.arm(now: 0)
        var t = 0.0
        while t < 1.2 {
            t += 0.016
            try expect(a.afterTick(now: t, changed: false, busy: { true }), "animating at \(t)")
        }
        try expect(a.afterTick(now: t + 0.016, changed: true, busy: { false }), "shown on the warp's end")
    }

    test("OverlayArmEvents: animating arms for the idle spell — the animation itself keeps it armed") {
        try expectEqual(OverlayArmEvents.hold(forBang: "sd.window.animating"), OverlayTickArm.idle)
    }

    test("OverlayArmEvents: unrelated bangs don't arm") {
        try expect(OverlayArmEvents.hold(forBang: "sd.window.created") == nil)
        try expect(OverlayArmEvents.hold(forBang: "sd.window.titleChanged") == nil)
    }
    test("OverlayTickArm: an armed spell with no tick for the stall window is stalled, and the backstop takes over") {
        // The vsync link can go silent while subscribed (displays asleep,
        // screen locked, a display reconfiguration). Armed forever with no
        // tick would freeze the overlay on its last frame.
        var a = OverlayTickArm()
        _ = a.arm(now: 10)
        try expect(!a.isStalled(now: 10 + OverlayTickArm.stallAfter - 0.01))
        try expect(!a.wantsBackstop(now: 10 + OverlayTickArm.stallAfter - 0.01))
        try expect(a.isStalled(now: 10 + OverlayTickArm.stallAfter + 0.01))
        try expect(a.wantsBackstop(now: 10 + OverlayTickArm.stallAfter + 0.01))
    }

    test("OverlayTickArm: every tick postpones the stall") {
        var a = OverlayTickArm()
        _ = a.arm(now: 0, hold: 10)
        var t = 0.0
        for _ in 0..<200 {
            t += 0.016
            _ = a.afterTick(now: t, changed: true, busy: { false })
            try expect(!a.isStalled(now: t))
        }
        try expect(a.isStalled(now: t + OverlayTickArm.stallAfter + 0.01))
    }

    test("OverlayTickArm: a disarmed overlay is never stalled") {
        var a = OverlayTickArm()
        try expect(!a.isStalled(now: 1_000))
        _ = a.arm(now: 0)
        _ = a.afterTick(now: idle + 0.01, changed: false, busy: { false })
        try expect(!a.armed)
        try expect(!a.isStalled(now: 1_000))
    }

    test("OverlayTickArm: recovering from a stall disarms, so the next arm reports the subscribe edge again") {
        var a = OverlayTickArm()
        _ = a.arm(now: 0)
        try expect(!a.arm(now: 5), "wedged: still counts as subscribed")
        a.recoverFromStall()
        try expect(!a.armed)
        try expect(a.arm(now: 5), "caller resubscribes to vsync")
        try expect(!a.isStalled(now: 5.1))
    }

    test("OverlayHandle: the backstop recovers an armed overlay whose vsync link went silent") {
        guard let text = try? String(contentsOfFile: "Sources/DataSources/OverlayHandle.swift", encoding: .utf8) else {
            throw Expectation(message: "run the tests from the repo root")
        }
        guard let backstop = text.components(separatedBy: "private func backstopTick()").last?
            .components(separatedBy: "\n    }\n").first else {
            throw Expectation(message: "backstopTick moved; update this guard")
        }
        try expect(backstop.contains("wantsBackstop(now:"), "the backstop must ask whether the armed link is silent")
        try expect(backstop.contains("recoverFromSilentLink()"), "a stalled overlay must recover, not wait for the link")
        try expect(text.contains("DisplayLinkObserver.shared.relink()"), "recovery must restart the link itself")
    }
}
