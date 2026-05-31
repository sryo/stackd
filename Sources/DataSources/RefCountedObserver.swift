import Foundation

/// Base class for observer singletons that want lazy native activation.
///
/// Subclasses override `install()` to set up their native plumbing
/// (NotificationCenter, IOKit, CGEventTap, etc.) and return a `Token`
/// whose `cancel` tears it all down. The base class:
///
///  - calls `install()` when subscriber count goes 0 → 1
///  - schedules teardown after a debounce delay when count goes 1 → 0
///  - cancels pending teardown if a new subscribe arrives during the gap
///  - fires every subscriber when `fire()` is called from the native callback
///
/// The debounce matters: hot-reload (file save → FSEvents → unloadStack →
/// loadStack) cycles a stack off+on within ~300ms. Tearing the native
/// listener down and recreating it would churn CoreAudio listeners, IOKit
/// runloop sources, AX observers, etc. for no benefit. Default delay is
/// 5 seconds — long enough to absorb hot-reload, short enough that a
/// genuinely-no-subscribers idle state stops consuming resources.
class RefCountedObserver {
    /// Subclass can override to tune the gap between last-unsubscribe and
    /// native teardown. 5 seconds covers hot-reload comfortably.
    var teardownDelay: TimeInterval { 5.0 }

    private var subs: [Int: () -> Void] = [:]
    private var nextId: Int = 1
    private var nativeToken: Token?
    private var teardownWork: DispatchWorkItem?

    init() {}

    /// Override to install native plumbing. Return a Token whose cancel
    /// closure tears down everything `install()` set up. Called when subscriber
    /// count goes 0 → 1; not called again until after a full teardown.
    func install() -> Token {
        fatalError("RefCountedObserver subclass must override install()")
    }

    /// Subclasses call this from their native callback to notify every subscriber.
    /// Safe to call before any subscribers exist (no-op).
    func fire() {
        for cb in subs.values { cb() }
    }

    /// Whether the observer is currently active (has a live native listener).
    /// Exposed for diagnostics; not used by subclasses.
    var isActive: Bool { nativeToken != nil }

    func subscribe(_ cb: @escaping () -> Void) -> Token {
        // Cancel any pending teardown — the gap closed before the timer fired.
        teardownWork?.cancel()
        teardownWork = nil

        if nativeToken == nil { nativeToken = install() }

        let id = nextId
        nextId += 1
        subs[id] = cb

        // Match the legacy pattern: subscribers expect to be primed immediately
        // so stacks render correct initial state before the first system event.
        cb()

        return Token { [weak self] in self?.unsubscribe(id) }
    }

    private func unsubscribe(_ id: Int) {
        subs.removeValue(forKey: id)
        guard subs.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.subs.isEmpty else { return }
            self.nativeToken?.cancel()
            self.nativeToken = nil
        }
        teardownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + teardownDelay, execute: work)
    }
}
