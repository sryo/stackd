import CoreGraphics
import Foundation

// External-monitor brightness arrives over DDC/CI: an I²C write, a 50ms settle
// sleep, an I²C read. `sd.display.all` is rebuilt on main from a 1s poll, so
// reading DDC inline would stall the main thread every tick. The reader below
// answers from a cache and refreshes it on a background queue.

/// Per-display cache state, pure so the staleness rules are testable with an
/// explicit clock. Callers serialize access.
struct BrightnessCache {
    /// Identifies one refresh request. A completion whose ticket predates an
    /// `invalidate` is dropped, so a read that raced a set can't put the old
    /// value back.
    struct Ticket: Equatable {
        let displayID: CGDirectDisplayID
        fileprivate let generation: Int
    }

    struct Lookup {
        /// Last known brightness (0...1), nil when never read or unreadable.
        let value: Float?
        /// Non-nil when the caller should perform one read and report back.
        let refresh: Ticket?
    }

    private struct Entry {
        var value: Float?
        var readAt: TimeInterval?
        var generation = 0
        var refreshing = false
    }

    let ttl: TimeInterval
    private var entries: [CGDirectDisplayID: Entry] = [:]

    init(ttl: TimeInterval) { self.ttl = ttl }

    /// Never blocks and never reports "no answer" for a display it has seen:
    /// an expired entry still returns its last value, alongside a ticket for
    /// one refresh (none while a refresh is already in flight).
    mutating func lookup(_ id: CGDirectDisplayID, now: TimeInterval) -> Lookup {
        var entry = entries[id] ?? Entry()
        let fresh = entry.readAt.map { now - $0 < ttl } ?? false
        var ticket: Ticket?
        if !fresh && !entry.refreshing {
            entry.refreshing = true
            ticket = Ticket(displayID: id, generation: entry.generation)
        }
        entries[id] = entry
        return Lookup(value: entry.value, refresh: ticket)
    }

    mutating func complete(_ ticket: Ticket, value: Float?, now: TimeInterval) {
        guard var entry = entries[ticket.displayID], entry.generation == ticket.generation else { return }
        entry.value = value
        entry.readAt = now
        entry.refreshing = false
        entries[ticket.displayID] = entry
    }

    /// A read made outside the refresh path (an explicit `getBrightness`).
    mutating func record(_ id: CGDirectDisplayID, value: Float?, now: TimeInterval) {
        var entry = entries[id] ?? Entry()
        entry.value = value
        entry.readAt = now
        entries[id] = entry
    }

    /// The display's brightness was just written. Makes the cached read stale
    /// so the next lookup requests a confirming one, and serves `assuming`
    /// (the value written) meanwhile so a subscriber doesn't see the old
    /// value flash back.
    mutating func invalidate(_ id: CGDirectDisplayID, assuming: Float?) {
        var entry = entries[id] ?? Entry()
        if let assumed = assuming { entry.value = assumed }
        entry.readAt = nil
        entry.refreshing = false
        entry.generation += 1
        entries[id] = entry
    }
}

/// Serves brightness from a `BrightnessCache` and runs the slow reads on
/// `queue`. Lookups never wait for a read.
final class BrightnessReader {
    private let lock = NSLock()
    private var cache: BrightnessCache
    private let queue: DispatchQueue
    private let clock: () -> TimeInterval
    private let read: (CGDirectDisplayID) -> Float?

    init(ttl: TimeInterval,
         queue: DispatchQueue,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         read: @escaping (CGDirectDisplayID) -> Float?) {
        self.cache = BrightnessCache(ttl: ttl)
        self.queue = queue
        self.clock = clock
        self.read = read
    }

    func brightness(of id: CGDirectDisplayID) -> Float? {
        lock.lock()
        let result = cache.lookup(id, now: clock())
        lock.unlock()
        if let ticket = result.refresh {
            queue.async { [self] in
                let value = read(id)
                lock.lock()
                cache.complete(ticket, value: value, now: clock())
                lock.unlock()
            }
        }
        return result.value
    }

    func record(_ id: CGDirectDisplayID, value: Float?) {
        lock.lock(); defer { lock.unlock() }
        cache.record(id, value: value, now: clock())
    }

    func invalidate(_ id: CGDirectDisplayID, assuming: Float?) {
        lock.lock(); defer { lock.unlock() }
        cache.invalidate(id, assuming: assuming)
    }
}
