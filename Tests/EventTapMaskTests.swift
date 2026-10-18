import CoreGraphics
import Foundation

// The interest masks of the two CGEventTaps follow what is registered. Taps
// are never created here (that needs Accessibility and would intercept the
// real session); the sizing and lifecycle decisions are pure functions.

func registerEventTapMaskTests() {
    func bit(_ type: CGEventType) -> CGEventMask { 1 << CGEventMask(type.rawValue) }

    // MARK: - neededConsumeMask

    test("neededConsumeMask: nothing registered needs no events") {
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: [], claim: nil), 0)
    }

    test("neededConsumeMask: grows by one bit per consumer type") {
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: [.leftMouseDown], claim: nil),
                        bit(.leftMouseDown))
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: [.leftMouseDown, .keyDown], claim: nil),
                        bit(.leftMouseDown) | bit(.keyDown))
    }

    test("neededConsumeMask: a scroll claim needs scrollWheel with no consumer") {
        let claim = ScrollClaim(senderId: nil, owner: "a")
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: [], claim: claim), bit(.scrollWheel))
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: [.keyDown], claim: claim),
                        bit(.keyDown) | bit(.scrollWheel))
    }

    test("neededConsumeMask: shrinks back to zero once the last consumer and the claim are gone") {
        let claim = ScrollClaim(senderId: 7, owner: "a")
        var consumers: Set<CGEventType> = [.leftMouseDown, .scrollWheel]
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: consumers, claim: claim),
                        bit(.leftMouseDown) | bit(.scrollWheel))
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: consumers, claim: nil),
                        bit(.leftMouseDown) | bit(.scrollWheel), "a scrollWheel consumer outlives the claim")
        consumers.remove(.scrollWheel)
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: consumers, claim: claim),
                        bit(.leftMouseDown) | bit(.scrollWheel), "the claim keeps scrollWheel")
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: consumers, claim: nil), bit(.leftMouseDown))
        consumers.remove(.leftMouseDown)
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: consumers, claim: nil), 0)
    }

    test("neededConsumeMask: the gesture event type gets its own bit") {
        try expectEqual(EventTapRegistry.neededConsumeMask(consumers: [Gesture.cgEventType], claim: nil),
                        1 << 29)
    }

    // MARK: - tapMaskAction

    test("tapMaskAction: an installed, enabled tap with nothing needed is disabled") {
        try expectEqual(EventTapRegistry.tapMaskAction(needed: 0, installed: bit(.leftMouseDown), enabled: true),
                        .disable)
    }

    test("tapMaskAction: nothing needed leaves an absent or already disabled tap alone") {
        try expectEqual(EventTapRegistry.tapMaskAction(needed: 0, installed: nil, enabled: false), .keep)
        try expectEqual(EventTapRegistry.tapMaskAction(needed: 0, installed: bit(.keyDown), enabled: false), .keep)
    }

    test("tapMaskAction: the first need installs a tap with exactly that mask") {
        try expectEqual(EventTapRegistry.tapMaskAction(needed: bit(.keyDown), installed: nil, enabled: false),
                        .reinstall(bit(.keyDown)))
    }

    test("tapMaskAction: an enabled tap that already covers the need is kept") {
        try expectEqual(
            EventTapRegistry.tapMaskAction(needed: bit(.keyDown),
                                           installed: bit(.keyDown) | bit(.keyUp), enabled: true),
            .keep)
    }

    test("tapMaskAction: a need outside the installed mask reinstalls with exactly the need") {
        try expectEqual(
            EventTapRegistry.tapMaskAction(needed: bit(.keyDown) | bit(.scrollWheel),
                                           installed: bit(.keyDown) | bit(.leftMouseDown), enabled: true),
            .reinstall(bit(.keyDown) | bit(.scrollWheel)))
    }

    test("tapMaskAction: a disabled tap whose mask is the need is re-enabled") {
        try expectEqual(
            EventTapRegistry.tapMaskAction(needed: bit(.leftMouseDown), installed: bit(.leftMouseDown), enabled: false),
            .enable)
    }

    test("tapMaskAction: a disabled tap with a stale wider mask is rebuilt instead of re-enabled") {
        try expectEqual(
            EventTapRegistry.tapMaskAction(needed: bit(.leftMouseDown),
                                           installed: bit(.leftMouseDown) | bit(.keyDown), enabled: false),
            .reinstall(bit(.leftMouseDown)))
    }
}
