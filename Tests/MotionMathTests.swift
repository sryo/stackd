import Foundation

// MotionMath — pure easing + spring math behind animated
// sd.windows.setFrame. The spring is the standard critically-damped
// harmonic oscillator closed form (implemented from the physics, not
// ported — OmniWM, the behavioral reference, is GPL-licensed).
func registerMotionMathTests() {
    test("easeOutCubic endpoints and midpoint") {
        try expectEqual(MotionMath.easeOutCubic(0), 0)
        try expectEqual(MotionMath.easeOutCubic(1), 1)
        // 1 - (1-0.5)^3 = 0.875
        try expect(abs(MotionMath.easeOutCubic(0.5) - 0.875) < 1e-12, "midpoint")
    }

    test("easeOutCubic is monotone increasing on [0,1]") {
        var prev = MotionMath.easeOutCubic(0)
        for i in 1...100 {
            let v = MotionMath.easeOutCubic(Double(i) / 100)
            try expect(v >= prev, "not monotone at t=\(Double(i) / 100)")
            prev = v
        }
    }

    test("linear is identity clamped to [0,1]") {
        try expectEqual(MotionMath.linear(0.25), 0.25)
        try expectEqual(MotionMath.linear(-1), 0)
        try expectEqual(MotionMath.linear(2), 1)
    }

    test("spring starts at from with initial velocity") {
        let s = MotionMath.Spring(from: 100, target: 500, initialVelocity: 42)
        try expect(abs(s.value(at: 0) - 100) < 1e-9, "value(0) != from")
        try expect(abs(s.velocity(at: 0) - 42) < 1e-9, "velocity(0) != v0")
    }

    test("spring converges to target") {
        let s = MotionMath.Spring(from: 0, target: 1000, initialVelocity: 0)
        try expect(abs(s.value(at: 2.0) - 1000) < 0.001, "not converged at t=2s")
        try expect(abs(s.velocity(at: 2.0)) < 0.001, "velocity not decayed at t=2s")
    }

    test("critically damped spring never overshoots (v0 = 0)") {
        let up = MotionMath.Spring(from: 0, target: 300, initialVelocity: 0)
        let down = MotionMath.Spring(from: 300, target: 0, initialVelocity: 0)
        for i in 0...200 {
            let t = Double(i) * 0.005
            try expect(up.value(at: t) <= 300 + 1e-9, "overshoot up at t=\(t)")
            try expect(down.value(at: t) >= -1e-9, "overshoot down at t=\(t)")
        }
    }

    test("spring settle predicate flips once displaced motion decays") {
        let s = MotionMath.Spring(from: 0, target: 400, initialVelocity: 0)
        try expect(!s.isSettled(at: 0, epsilon: 0.5, velocityEpsilon: 5), "settled at t=0")
        try expect(s.isSettled(at: 3, epsilon: 0.5, velocityEpsilon: 5), "not settled at t=3s")
    }

    test("spring velocity carryover is continuous across handoff") {
        // Interrupting spring A mid-flight and seeding spring B with A's
        // instantaneous velocity must produce a B whose t=0 velocity equals
        // the handoff velocity — the momentum-carryover contract.
        let a = MotionMath.Spring(from: 0, target: 100, initialVelocity: 0)
        let tHand = 0.05
        let v = a.velocity(at: tHand)
        let x = a.value(at: tHand)
        try expect(v > 0, "expected in-flight velocity")
        let b = MotionMath.Spring(from: x, target: 700, initialVelocity: v)
        try expect(abs(b.velocity(at: 0) - v) < 1e-9, "handoff velocity discontinuity")
        try expect(abs(b.value(at: 0) - x) < 1e-9, "handoff position discontinuity")
    }
}
