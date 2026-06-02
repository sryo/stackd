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
    ///
    /// Return nil to indicate a transient failure (e.g. Accessibility denied,
    /// CoreAudio device unavailable). The base class does NOT cache the
    /// result, so the next subscribe will retry install — important for the
    /// "user grants permission while a stack is already subscribed" path.
    func install() -> Token? {
        fatalError("RefCountedObserver subclass must override install()")
    }

    /// Subclasses call this from their native callback to notify every subscriber.
    /// Safe to call before any subscribers exist (no-op).
    ///
    /// Snapshots `subs.values` into an Array before iterating so a callback
    /// that synchronously unsubscribes (or unloads a stack, which drains a
    /// scope whose Tokens remove from this dict) doesn't mutate the
    /// Dictionary mid-iteration — that would be undefined behavior in Swift.
    func fire() {
        for cb in Array(subs.values) { cb() }
    }

    /// Lazy fire: only fan out if the supplied hash differs from the last one
    /// stored under `key`. Use for polling observers where the snapshot
    /// usually doesn't change between ticks — privacy device list, sensors
    /// reading, menubar items. The poll still runs (we need the snapshot to
    /// compute the hash), but Bridge `jsonify` + per-stack `evaluateJavaScript`
    /// fan-out is skipped on no-op ticks. With many stacks subscribing,
    /// avoiding the per-stack push dominates the savings; the AX/CoreAudio
    /// snapshot itself is usually cheap.
    ///
    /// Key is per-observer (channel name, conventionally) so a single
    /// observer can dedup multiple logical streams independently. Hash is
    /// the caller's choice — `Hasher.combine`-derived ints are standard.
    private var lastHashByKey: [String: Int] = [:]
    func fireIfChanged(_ key: String, hash: Int) {
        if lastHashByKey[key] == hash { return }
        lastHashByKey[key] = hash
        fire()
    }

    /// Whether the observer is currently active (has a live native listener).
    /// Exposed for diagnostics; not used by subclasses.
    var isActive: Bool { nativeToken != nil }

    func subscribe(_ cb: @escaping () -> Void) -> Token {
        // Cancel any pending teardown — the gap closed before the timer fired.
        teardownWork?.cancel()
        teardownWork = nil

        // Retry install on every subscribe while we don't have a live token.
        // If install returns nil (transient failure), nativeToken stays nil
        // and the NEXT subscribe gets another shot — e.g. a stack stays
        // subscribed while the user grants Accessibility in System Settings.
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

// MARK: - NotificationCenter install/teardown sugar

extension RefCountedObserver {
    /// Install a batch of `NotificationCenter.addObserver` calls — each spec
    /// fires `self.fire()` on the main queue — and return a Token that
    /// removes all of them on cancel.
    ///
    /// The "every observer just calls `self?.fire()`" shape is by far the
    /// most common in DataSources/. Pre-helper, each observer cost ~6 lines
    /// of identical add/remove wiring; this collapses them to one literal.
    /// For observers that need per-spec side effects (state flips, KVO
    /// rebinds, userInfo decoding) use the (center, name, handler) overload.
    func installNotifications(
        _ specs: [(NotificationCenter, Notification.Name)]
    ) -> Token {
        let tokens: [(NotificationCenter, NSObjectProtocol)] = specs.map { center, name in
            let t = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.fire()
            }
            return (center, t)
        }
        return Token {
            for (center, t) in tokens { center.removeObserver(t) }
        }
    }

    /// Install a batch of `NotificationCenter.addObserver` calls where each
    /// spec carries its own handler — for observers that need per-name side
    /// effects beyond `self?.fire()` (state flips, userInfo decoding, etc.).
    /// Handlers run on the main queue. The returned Token removes every
    /// observer it registered.
    func installNotifications(
        _ specs: [(NotificationCenter, Notification.Name, (Notification) -> Void)]
    ) -> Token {
        let tokens: [(NotificationCenter, NSObjectProtocol)] = specs.map { center, name, handler in
            let t = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
            return (center, t)
        }
        return Token {
            for (center, t) in tokens { center.removeObserver(t) }
        }
    }
}
