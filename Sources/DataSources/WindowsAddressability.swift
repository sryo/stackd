import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - WindowTraits
//
// Whether a window can take an arbitrary size. Tilers read these to tell a
// document window from a fixed-size panel that still reports
// AXStandardWindow (Calculator, About This Mac, an app's Settings, Finder's
// Get Info).
struct WindowTraits: Equatable {
    /// kAXSizeAttribute is settable.
    let isResizable: Bool
    /// The window has an enabled AXFullScreenButton.
    let canFullscreen: Bool

    enum Button { case enabled, disabled, absent, unreadable }

    /// `sizeSettable == nil` is an unreadable attribute. Unreadable readings
    /// fail open (resizable, fullscreen-capable) so an AX timeout never
    /// treats an ordinary window as a panel.
    static func from(sizeSettable: Bool?, fullscreenButton: Button) -> WindowTraits {
        WindowTraits(isResizable: sizeSettable ?? true,
                     canFullscreen: fullscreenButton == .enabled || fullscreenButton == .unreadable)
    }

    /// Blocks for up to the element's AX messaging timeout per read.
    static func read(_ el: AXUIElement) -> WindowTraits {
        var settable: DarwinBoolean = false
        let sizeErr = AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
        var btnRef: AnyObject?
        let btnErr = AXUIElementCopyAttributeValue(el, kAXFullScreenButtonAttribute as CFString, &btnRef)
        let button: Button
        switch btnErr {
        case .success:
            var enabledRef: AnyObject?
            if let btn = btnRef, CFGetTypeID(btn) == AXUIElementGetTypeID(),
               AXUIElementCopyAttributeValue(btn as! AXUIElement, kAXEnabledAttribute as CFString, &enabledRef) == .success,
               let enabled = enabledRef as? Bool {
                button = enabled ? .enabled : .disabled
            } else {
                button = .unreadable
            }
        case .noValue, .attributeUnsupported:
            button = .absent
        default:
            button = .unreadable
        }
        return from(sizeSettable: sizeErr == .success ? settable.boolValue : nil, fullscreenButton: button)
    }

    var fields: [String: Any] { ["isResizable": isResizable, "canFullscreen": canFullscreen] }
}

// MARK: - WindowAddressabilityCache
//
// AX probe results for each (pid, CGWindowID) cached with a TTL. Used to
// enrich Windows.all() without paying an AX round-trip per window per push.
// The elementFor + subrole lookup never runs on the caller's thread: a
// missing or expired verdict starts one read on the app's AXAppQueues
// queue (AddressabilityReads) and the caller gets the last known verdict,
// or the pending one for an unseen window. The read's result lands on main,
// and a change in what Windows.all() reports re-pumps sd.windows.all.
// Reads within the TTL hit the cache. Entries are dropped per window on
// window-destroyed events and per pid when the app terminates.
//
// Why on the daemon side: lets every stack consume sd.windows.all without
// each one re-implementing per-pass probing — otherwise a tiler does
// 2N AX calls per tile pass, costly and racy.
enum WindowAddressabilityCache {
    struct Probe {
        let addressable: Bool
        let isStandard: Bool
        let isMinimized: Bool
        let ts: TimeInterval
        /// Consecutive failed probes of an unaddressable window, or failed
        /// trait reads of a standard one; scales its re-probe gate
        /// (failTtl(after:)).
        var failures: Int = 0
        /// nil until a read of the live element has taken them.
        var traits: WindowTraits? = nil
    }
    struct Key: Hashable {
        let pid: pid_t
        let windowID: CGWindowID
    }
    private static var cache: [Key: Probe] = [:]
    /// Live (uncached) probes since the last `takeLiveProbeCount()`, for the
    /// debug timing line in Windows.all().
    private static var liveProbes = 0
    // First-seen wall-time per (pid, windowID). A window gets a grace
    // window of OPTIMISTIC_GRACE_MS during which probe misses report
    // addressable=true (instead of false). Avoids the boot-burst race
    // where AX is slammed and Terminal's first 5+ probes time out in
    // milliseconds. Once the grace expires, real misses mark false.
    private static var firstSeenAt: [Key: TimeInterval] = [:]
    private static let optimisticGraceMs: TimeInterval = 5.0
    private static let lock = NSLock()
    // Positive probes (addressable AND standard) are cached PERMANENTLY
    // (until pid death — AppDelegate's NSWorkspace.didTerminateApplication
    // observer drops the pid). Reasoning: AX's 100ms messaging timeout drops
    // queries under load (spotlight indexing, brightness poll, rapid tile
    // passes); a once-addressable standard window doesn't randomly stop
    // being one while its pid is alive. Re-probing on TTL expiry would let
    // a transient AX timeout drop a once-established verdict.
    // Negative isStandard verdicts are NOT permanent: a probe racing a
    // minimize/deminimize/space-restore transition can read a bogus subrole
    // (Terminal reports AXDialog mid-transition while AXMinimized already
    // reads false), and a permanent false verdict silently drops a real
    // window out of Windows.all() with no heal path — no poll, rescan, or
    // event ever re-probes it. nonStandardTtl bounds the damage: a genuine
    // dialog/sheet just re-confirms once per TTL (≤1 AX read per layer-0
    // non-standard window), a poisoned real window heals on the first
    // re-probe after the transition settles — worst case nonStandardTtl
    // plus one 10s poll tick on an otherwise idle system.
    // Failed probes are re-checked quickly at first so an app that JUST
    // opened a window gets re-evaluated within a beat, then less and less
    // often: a window that keeps failing is one AX does not vend (helper
    // chrome, offscreen surfaces), and Windows.all() runs for every
    // create/destroy/focus push — re-probing ~100 of them at a flat 0.5s
    // keeps every app's AX queue busy for nothing. Windows that do become
    // addressable later are found without the timer: the AX create observer
    // and CGS 1325 re-finds confirm() them, and a space change calls
    // retryFailures().
    static let failTtl: TimeInterval = 0.5
    static let failTtlCap: TimeInterval = 30.0
    static let nonStandardTtl: TimeInterval = 3.0

    /// Re-probe gate for an unaddressable verdict after `failures`
    /// consecutive failures: failTtl, doubling per failure, capped.
    /// Once capped, the gate is stretched by a per-window factor in [1, 2)
    /// so windows that failed equally often don't all come due in the same
    /// Windows.all() call.
    static func failTtl(after failures: Int, windowID: CGWindowID = 0) -> TimeInterval {
        let doublings = min(max(0, failures - 1), 16)
        let gate = failTtl * Double(1 << doublings)
        guard gate >= failTtlCap else { return gate }
        return failTtlCap * (1 + Double(windowID % 16) / 16)
    }

    /// Whether a cached probe may be returned as-is or must be re-read
    /// live. Pure so the expiry rules above are unit-testable.
    static func cacheVerdictUsable(_ p: Probe, now: TimeInterval, windowID: CGWindowID = 0) -> Bool {
        if p.addressable {
            guard p.isStandard else { return (now - p.ts) < nonStandardTtl }
            // A standard window without traits (seeded by confirm(), or its
            // trait read failed) reads them now, then backs off per failure.
            return p.traits != nil
                || (p.failures > 0 && (now - p.ts) < failTtl(after: p.failures, windowID: windowID))
        }
        return (now - p.ts) < failTtl(after: p.failures, windowID: windowID)
    }

    /// A cached verdict (or the pending one) plus whether a live AX read is
    /// due. Never touches AX.
    struct Lookup {
        let probe: Probe
        let needsRead: Bool
    }

    /// One finished AX read of a window whose element resolved. A read whose
    /// element did not resolve is recorded as `nil`.
    struct Reading: Equatable {
        let isStandard: Bool
        let isMinimized: Bool
        var traits: WindowTraits? = nil
        var subroleError: Int32 = 0
    }

    /// What Windows.all() reports for a window with no verdict yet: kept as
    /// a candidate (addressable) but not standard, so a tiler never takes a
    /// sheet or dialog whose subrole is still unknown.
    static func pending(now: TimeInterval) -> Probe {
        Probe(addressable: true, isStandard: false, isMinimized: false, ts: now)
    }

    /// Never blocks: returns the usable cached verdict, or — when it is
    /// missing or expired — the last known verdict (pending for an unseen
    /// window) and starts one off-main AX read on the app's AXAppQueues
    /// queue. When that read changes what Windows.all() reports, the
    /// windows channel is re-pumped (see `readResolved`).
    static func probe(pid: pid_t, windowID: CGWindowID,
                      now: TimeInterval = Date().timeIntervalSince1970) -> Probe {
        let l = lookup(pid: pid, windowID: windowID, now: now)
        if l.needsRead { requestRead(Key(pid: pid, windowID: windowID)) }
        return l.probe
    }

    static func lookup(pid: pid_t, windowID: CGWindowID, now: TimeInterval) -> Lookup {
        let key = Key(pid: pid, windowID: windowID)
        lock.lock(); defer { lock.unlock() }
        guard let p = cache[key] else {
            // Grace runs from first sight: the read that settles this
            // window may land well after the pass that first listed it.
            if firstSeenAt[key] == nil { firstSeenAt[key] = now }
            return Lookup(probe: pending(now: now), needsRead: true)
        }
        return Lookup(probe: p, needsRead: !cacheVerdictUsable(p, now: now, windowID: windowID))
    }

    /// Folds one finished read into the cache. `changed` is whether the
    /// verdict Windows.all() reports for the window (addressable, standard,
    /// minimized) differs from what it reported while the read was pending.
    @discardableResult
    static func record(pid: pid_t, windowID: CGWindowID, reading: Reading?,
                       now: TimeInterval) -> (probe: Probe, changed: Bool) {
        let key = Key(pid: pid, windowID: windowID)
        lock.lock()
        let existing = cache[key]
        let before = existing ?? pending(now: now)
        let probe: Probe
        let shouldCache: Bool
        if let r = reading {
            // Success — cache true permanently.
            probe = Probe(addressable: true, isStandard: r.isStandard, isMinimized: r.isMinimized, ts: now,
                          traits: r.traits)
            shouldCache = true
        } else if let e = existing, e.addressable {
            // Sticky-success: established-true never flips to false on a
            // transient miss. Keep the whole cached verdict — the read
            // FAILED, so it carries no minimized reading; live minimize
            // flips arrive via setMinimized().
            // ts=now also paces an expired negative-isStandard entry: each
            // failed re-probe buys one more nonStandardTtl of patience
            // instead of re-reading AX on every Windows.all() pass.
            probe = Probe(addressable: true, isStandard: e.isStandard, isMinimized: e.isMinimized, ts: now,
                          failures: e.traits == nil ? e.failures + 1 : 0, traits: e.traits)
            shouldCache = true
        } else {
            // No success yet. Time-based optimism: report the pending
            // verdict (addressable: true, isStandard: false) for the first
            // optimisticGraceMs after we first saw the id. AX is slammed at
            // boot — 5+ misses can happen in milliseconds, count-based
            // thresholds get blown through. Time-based gives the app a fair
            // shot at responding before we mark it dead.
            let firstSeen = firstSeenAt[key] ?? now
            if firstSeenAt[key] == nil { firstSeenAt[key] = now }
            if (now - firstSeen) < optimisticGraceMs {
                // NOT cached: the sticky-success branch above would lock in
                // `addressable: true, isStandard: false` for the window's
                // lifetime, and every window seen during an AX-stress burst
                // (boot, restart, spotlight indexing) would never re-enter
                // tile rotation. Uncached, the next pass reads again.
                probe = pending(now: now)
                shouldCache = false
            } else {
                probe = Probe(addressable: false, isStandard: false, isMinimized: false, ts: now,
                              failures: (existing?.failures ?? 0) + 1)
                shouldCache = true
            }
        }
        if shouldCache { cache[key] = probe }
        lock.unlock()
        let changed = before.addressable != probe.addressable
            || before.isStandard != probe.isStandard
            || before.isMinimized != probe.isMinimized
            || before.traits != probe.traits
        // Verdict flips are rare and are what silently drops a window from
        // every tiler — say why.
        if shouldCache, let old = existing,
           old.addressable != probe.addressable || old.isStandard != probe.isStandard {
            log("windows: wid=\(windowID) pid=\(pid) addressable \(old.addressable)→\(probe.addressable) standard \(old.isStandard)→\(probe.isStandard) (element \(reading == nil ? "unresolved" : "ok"), subrole read \(reading?.subroleError ?? 0))")
        } else if shouldCache, existing == nil, !probe.addressable {
            // Common for layer-0 windows AX doesn't vend (helpers, offscreen
            // chrome) — debug-only; the flips above are the signal.
            WindowDebug.log("windows: wid=\(windowID) pid=\(pid) unaddressable after grace (element unresolved)")
        }
        return (probe, changed)
    }

    /// The AX half of a probe: resolve the element and read its minimized
    /// flag and subrole. Blocks for up to the AX messaging timeout per call
    /// when the app is stuck, so it runs only on the app's AXAppQueues queue.
    static func readAX(pid: pid_t, windowID: CGWindowID) -> Reading? {
        for attempt in 0..<2 {
            guard let e = WindowsByID.elementFor(windowID: windowID, pid: pid) else { return nil }
            let read = WindowAXRead(e, [kAXMinimizedAttribute, kAXSubroleAttribute])
            let isMin = read.bool(kAXMinimizedAttribute) ?? false
            let subroleErr = read.error(kAXSubroleAttribute)
            let isStd = standardVerdict(subrole: read.string(kAXSubroleAttribute), isMinimized: isMin)
            let reading = Reading(isStandard: isStd, isMinimized: isMin,
                                  traits: isStd ? WindowTraits.read(e) : nil,
                                  subroleError: subroleErr.rawValue)
            guard StaleElementRetry.shouldReResolve(readError: subroleErr, attempt: attempt) else { return reading }
            // The cached element may be dead while the window lives on
            // (sleep/wake): drop it so elementFor re-walks kAXWindows.
            WindowsByID.invalidateCache(pid: pid, windowID: windowID)
        }
        return nil
    }

    /// Main thread only.
    private static var reads = AddressabilityReads<Key>()
    private static var pumpScheduled = false

    private static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    private static func requestRead(_ key: Key) {
        onMain {
            guard let generation = reads.request(key) else { return }
            startRead(key, generation: generation)
        }
    }

    /// Main thread.
    private static func startRead(_ key: Key, generation: UInt64) {
        lock.lock(); liveProbes += 1; lock.unlock()
        AXAppQueues.queue(for: key.pid).async {
            let reading = readAX(pid: key.pid, windowID: key.windowID)
            let readAt = Date().timeIntervalSince1970
            DispatchQueue.main.async {
                readResolved(key, generation: generation, reading: reading, readAt: readAt)
            }
        }
    }

    /// Main thread. A verdict change re-pumps sd.windows.all once per main
    /// turn, however many reads land in it: consumers that filtered a
    /// pending window out (tilers checking isStandard) see it as soon as
    /// its read confirms it, not on the next unrelated window event.
    private static func readResolved(_ key: Key, generation: UInt64, reading: Reading?, readAt: TimeInterval) {
        switch reads.resolved(key, generation: generation) {
        case .discard:
            return
        case .rerun(let next):
            startRead(key, generation: next)
            return
        case .apply:
            break
        }
        guard record(pid: key.pid, windowID: key.windowID, reading: reading, now: readAt).changed,
              !pumpScheduled else { return }
        pumpScheduled = true
        DispatchQueue.main.async {
            pumpScheduled = false
            AppDelegate.shared?.host?.pumpWindowsListForAllStacks()
        }
    }

    /// Let every unaddressable verdict be re-probed on its next read, keeping
    /// its failure count: one fresh look (after a space change, when AX may
    /// now vend a window it did not), then the same backoff if it still fails.
    /// A read already in flight for such a window may have been taken before
    /// the change, so it is re-run rather than trusted.
    static func retryFailures() {
        lock.lock()
        for (key, p) in cache where !p.addressable {
            cache[key] = Probe(addressable: false, isStandard: false, isMinimized: false,
                               ts: -.infinity, failures: p.failures)
        }
        lock.unlock()
        restaleReads { !$0.addressable }
    }

    /// Marks in-flight reads stale for windows with no verdict yet or whose
    /// verdict matches `affected`.
    private static func restaleReads(_ affected: @escaping (Probe) -> Bool) {
        onMain {
            lock.lock()
            let snapshot = cache
            lock.unlock()
            reads.markStale { key in snapshot[key].map(affected) ?? true }
        }
    }

    /// Live probes since the previous call.
    static func takeLiveProbeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = liveProbes
        liveProbes = 0
        return n
    }

    /// Forget every verdict except established positives, so windows get
    /// re-probed with fresh elements (after wake).
    static func dropNonPositive() {
        lock.lock()
        cache = cache.filter { $0.value.addressable && $0.value.isStandard }
        firstSeenAt.removeAll()
        lock.unlock()
        restaleReads { _ in true }
    }

    /// Also forgets in-flight reads for the pid: their results are dropped.
    static func invalidate(pid: pid_t) {
        lock.lock()
        cache = cache.filter { $0.key.pid != pid }
        firstSeenAt = firstSeenAt.filter { $0.key.pid != pid }
        lock.unlock()
        onMain { reads.purge { $0.pid == pid } }
    }

    /// Single-window invalidation for the AX window-destroyed path. Document
    /// apps (Preview) keep closed windows alive in the WindowServer, so the
    /// id stays in CGWindowList while AX drops it — a sticky isStandard:true
    /// entry then feeds the ghost into sd.windows.all all session, so a
    /// consumer counts closed windows and never sees the app as windowless.
    /// One key only: the pid's OTHER windows keep their sticky verdicts
    /// (the reason destroy events must not use the pid-wide overload above).
    /// A falsely-reported destroy self-heals — the next probe re-establishes
    /// sticky success.
    static func invalidate(pid: pid_t, windowID: CGWindowID) {
        let key = Key(pid: pid, windowID: windowID)
        lock.lock()
        cache.removeValue(forKey: key)
        firstSeenAt.removeValue(forKey: key)
        lock.unlock()
        onMain { reads.purge { $0 == key } }
    }

    /// AX-confirmed verdict, bypassing the probe machinery. WindowsAXObserver
    /// already holds the window element at create time and read its subrole —
    /// re-deriving the same answer through `probe()` is not just wasteful but
    /// actively harmful: under AX load the probe lands in the optimism grace,
    /// which reports `isStandard: false`, which makes `Windows.all()` filter
    /// the just-created window OUT of the very snapshot AppDelegate pumps in
    /// response to the create. Seeds the same sticky-success entry a
    /// successful probe would, so the next `Windows.all()` pass includes the
    /// window as soon as CGWindowList lists it.
    static func confirm(pid: pid_t, windowID: CGWindowID, isStandard: Bool, isMinimized: Bool,
                        traits: WindowTraits? = nil,
                        now: TimeInterval = Date().timeIntervalSince1970) {
        let key = Key(pid: pid, windowID: windowID)
        lock.lock(); defer { lock.unlock() }
        // A standard window's traits don't change; keep any a list read took.
        let kept = isStandard ? (traits ?? cache[key]?.traits) : traits
        cache[key] = Probe(addressable: true, isStandard: isStandard, isMinimized: isMinimized, ts: now,
                           traits: kept)
    }

    /// Live isMinimized update from AX miniaturize/deminiaturize events.
    /// The sticky-success fast path in `probe()` returns the cached entry
    /// without re-reading AX, so without this hook the isMinimized bit
    /// freezes at whatever the first successful probe saw. No-op when the
    /// (pid, wid) has no established-success entry — the next real probe
    /// reads the live value anyway.
    /// The entry's ts is preserved: ts schedules a negative isStandard
    /// verdict's re-probe, and minimize events arrive exactly during the
    /// transitions that produce bogus negative verdicts — re-stamping here
    /// would let minimize churn push the heal deadline out indefinitely.
    static func setMinimized(pid: pid_t, windowID: CGWindowID, _ value: Bool) {
        let key = Key(pid: pid, windowID: windowID)
        lock.lock(); defer { lock.unlock() }
        guard let p = cache[key], p.addressable else { return }
        cache[key] = Probe(addressable: true, isStandard: p.isStandard, isMinimized: value, ts: p.ts,
                           failures: p.failures, traits: p.traits)
    }

    /// Subrole reading → isStandard verdict, minimize-aware. A minimized
    /// window's AXSubrole is unreliable — Terminal's minimized windows
    /// report AXDialog (macOS 26) — so a window whose first successful
    /// probe happened while it sat in the Dock would get sticky-cached as
    /// non-standard and filtered out of Windows.all(), leaving consumers to
    /// read the app as windowless. Only real user windows can be minimized
    /// to the Dock, so minimized ⇒ standard regardless of the reading.
    static func standardVerdict(subrole: String?, isMinimized: Bool) -> Bool {
        isMinimized || subrole == (kAXStandardWindowSubrole as String)
    }
}

/// Off-main read schedule for WindowAddressabilityCache probes, one AX read
/// per window at a time on the app's AXAppQueues queue.
///
/// A request while a read is in flight starts nothing: the running read
/// answers it, so a hung app accrues one pending read per window, not one
/// per Windows.all() pass. Each read carries a generation. `purge` (window
/// destroyed, app quit) forgets the key, so a late result resolves to
/// .discard and can't free a read started after the purge. `markStale`
/// (space change, wake) keeps the slot but turns the eventual result into
/// .rerun: a reading taken before the change is not trusted, and one fresh
/// read replaces it. Pure; the caller owns queues and main hops.
struct AddressabilityReads<Key: Hashable> {
    enum Resolution: Equatable {
        case apply
        /// Drop the result and start this generation's read instead.
        case rerun(UInt64)
        case discard
    }

    private struct Slot {
        var generation: UInt64
        var stale: Bool
    }
    private var inFlight: [Key: Slot] = [:]
    private var nextGeneration: UInt64 = 0

    /// The generation of a read to start now, or nil when one is in flight.
    mutating func request(_ key: Key) -> UInt64? {
        guard inFlight[key] == nil else { return nil }
        return start(key)
    }

    mutating func resolved(_ key: Key, generation: UInt64) -> Resolution {
        guard let slot = inFlight[key], slot.generation == generation else { return .discard }
        if slot.stale { return .rerun(start(key)) }
        inFlight[key] = nil
        return .apply
    }

    mutating func markStale(where matches: (Key) -> Bool) {
        for key in inFlight.keys where matches(key) { inFlight[key]?.stale = true }
    }

    mutating func purge(where matches: (Key) -> Bool) {
        inFlight = inFlight.filter { !matches($0.key) }
    }

    private mutating func start(_ key: Key) -> UInt64 {
        nextGeneration += 1
        inFlight[key] = Slot(generation: nextGeneration, stale: false)
        return nextGeneration
    }
}
