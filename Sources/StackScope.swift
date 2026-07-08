import Foundation

// Per-stack handle for native resources (observer subs, hotkeys, eventtaps,
// menubar suppressions, future AX observers). Every registry that today
// returns a bool/id from a registration call should return a Token instead;
// callers adopt it into a StackScope, and stack unload drains the scope.
//
// Dropping a Token without adopting it does NOT cancel. The contract is:
// adopt or explicitly cancel.
final class Token {
    let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
}

/// Owned by Bridge (1:1 with a stack). Every native resource a stack
/// allocates lands here; StackHost.unloadStack drains it on unload.
final class StackScope {
    private var tokens: [Token] = []

    /// Latches true once `drain()` runs. A stack's scope drains exactly once
    /// at unload, after which the Bridge is discarded — so an async resource
    /// creation (e.g. overlay.region.create) that lands AFTER the drain must
    /// bail rather than register a handle the one-shot teardown already ran
    /// past and can never reclaim. Overlay create paths gate on this.
    private(set) var isDrained = false

    func adopt(_ token: Token) { tokens.append(token) }

    /// Convenience for the common `scope.adopt(maybeToken)` pattern.
    /// Drops nils silently — parse failures (e.g. hotkey spec invalid)
    /// already log at the registry; no second log needed.
    func adopt(_ token: Token?) {
        if let t = token { tokens.append(t) }
    }

    /// Cancel in reverse registration order. Matters for layered resources
    /// (e.g. an AXObserver added to a per-pid AXAppObserver — tear down the
    /// notification before the observer's CFRunLoopSource).
    func drain() {
        isDrained = true
        for t in tokens.reversed() { t.cancel() }
        tokens.removeAll()
    }
}
