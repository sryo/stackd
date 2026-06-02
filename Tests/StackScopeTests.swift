import Foundation

func registerStackScopeTests() {
    test("adopt + drain runs every token's cancel exactly once") {
        let scope = StackScope()
        var calls: [String] = []
        scope.adopt(Token { calls.append("a") })
        scope.adopt(Token { calls.append("b") })
        scope.adopt(Token { calls.append("c") })
        scope.drain()
        try expectEqual(calls.sorted(), ["a", "b", "c"])
    }

    test("drain cancels in reverse registration order") {
        // Matters for layered resources (AXObserver subscription torn down
        // before the underlying CFRunLoopSource).
        let scope = StackScope()
        var order: [Int] = []
        scope.adopt(Token { order.append(1) })
        scope.adopt(Token { order.append(2) })
        scope.adopt(Token { order.append(3) })
        scope.drain()
        try expectEqual(order, [3, 2, 1])
    }

    test("drain is idempotent — second call is a no-op") {
        let scope = StackScope()
        var count = 0
        scope.adopt(Token { count += 1 })
        scope.adopt(Token { count += 1 })
        scope.drain()
        try expectEqual(count, 2)
        scope.drain() // must not re-invoke
        try expectEqual(count, 2)
    }

    test("adopt(nil) is silently dropped — no crash, no spurious cancel") {
        let scope = StackScope()
        var calls = 0
        let nilToken: Token? = nil
        scope.adopt(nilToken)
        scope.adopt(Token { calls += 1 })
        let alsoNil: Token? = nil
        scope.adopt(alsoNil)
        scope.drain()
        try expectEqual(calls, 1)
    }

    test("per-stack isolation — draining one scope leaves the other intact") {
        let a = StackScope()
        let b = StackScope()
        var aFired = 0
        var bFired = 0
        a.adopt(Token { aFired += 1 })
        b.adopt(Token { bFired += 1 })
        a.drain()
        try expectEqual(aFired, 1)
        try expectEqual(bFired, 0)
        b.drain()
        try expectEqual(bFired, 1)
    }

    test("adopt after drain — newly adopted tokens still fire on next drain") {
        // StackScope is a reusable container; drain() clears the list but
        // does not invalidate the scope itself.
        let scope = StackScope()
        var phase1 = 0
        var phase2 = 0
        scope.adopt(Token { phase1 += 1 })
        scope.drain()
        scope.adopt(Token { phase2 += 1 })
        scope.drain()
        try expectEqual(phase1, 1)
        try expectEqual(phase2, 1)
    }
}
