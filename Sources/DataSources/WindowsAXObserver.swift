import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - AXWakeRefresh
//
// When to rebuild the AX layer after the system wakes. While the session is
// locked AX vends no window lists, so a rebuild then attaches no per-window
// observers and minimize/move/resize events stay dead; a wake behind the
// lock screen waits for the unlock instead.
enum AXWakeRefresh {
    enum Event { case wake, unlock }

    static func shouldRefresh(on event: Event, screenLocked: Bool) -> Bool {
        switch event {
        case .wake:   return !screenLocked
        case .unlock: return true
        }
    }

    static func screenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = dict["CGSSessionScreenIsLocked"] as? Bool
        else { return false }
        return locked
    }
}

/// Whether a window's per-window AX observers need (re)attaching, given
/// what's stored and what AX resolves for it now. Generic so it's testable
/// without live AXUIElements.
enum PerWindowInstallDecision: Equatable {
    case install, replace, keep

    static func decide<T>(existing: T?, fresh: T?, same: (T, T) -> Bool) -> PerWindowInstallDecision {
        guard let fresh = fresh else { return .keep }
        guard let existing = existing else { return .install }
        return same(existing, fresh) ? .keep : .replace
    }
}

/// Per-app rate limit for the create-triggered AX install retry.
struct AXInstallRetryGate {
    static let minInterval: Double = 2.0
    private var lastAttempt: [pid_t: Double] = [:]

    mutating func shouldAttempt(pid: pid_t, now: Double) -> Bool {
        if let last = lastAttempt[pid], now - last < Self.minInterval { return false }
        lastAttempt[pid] = now
        return true
    }
}

/// Which listed windows lack per-window AX observers. Every attach path
/// can drop a window for good without a trace outside debug logging: the
/// subrole recheck ladder runs dry while the app is still building the
/// window, CGS 1325 lands before AX vends the element, the safety poll
/// suppresses a create another announcer already made. Such a window
/// still lists, tiles, and closes (CGS 804 covers destroy), but never
/// reports minimize, deminimize, moved, or resized. The safety poll
/// sweeps with this so the gap closes within one tick.
enum PerWindowCoverage {
    /// Minimum spacing between attach attempts for one window, so a window
    /// AX keeps refusing costs one AX walk a minute, not one per tick.
    static let retryInterval: Double = 60.0

    /// `rows` are `Windows.all()` entries. Only AX-addressable standard
    /// windows qualify: the probe already resolved those, so an attach is
    /// expected to succeed.
    static func uncovered(rows: [[String: Any]], covered: (Int) -> Bool) -> [(pid: Int, id: Int)] {
        rows.compactMap { r in
            guard let id = r["id"] as? Int, let pid = r["pid"] as? Int,
                  r["isStandard"] as? Bool == true, r["addressable"] as? Bool == true,
                  !covered(id) else { return nil }
            return (pid, id)
        }
    }

    struct Gate {
        private var lastAttempt: [Int: Double] = [:]

        mutating func shouldAttempt(id: Int, now: Double) -> Bool {
            if let last = lastAttempt[id], now - last < PerWindowCoverage.retryInterval { return false }
            lastAttempt[id] = now
            return true
        }

        /// Drop windows no longer listed, keeping the map bounded.
        mutating func retain(ids: Set<Int>) {
            lastAttempt = lastAttempt.filter { ids.contains($0.key) }
        }
    }
}

/// When to retry installing the frontmost app's AX observers. A
/// just-launched app is activated before it answers AX:
/// AXObserverAddNotification fails with kAXErrorCannotComplete until it
/// does (0.25-0.75 s measured on macOS 27 for Calculator, Font Book and
/// Notes). Nothing announces the moment it starts answering:
/// isFinishedLaunching and didLaunchApplication both land while the app is
/// still refusing, so the install is retried on a backoff, as yabai does.
/// Without the retry the app runs unobserved until the user switches away
/// and back, and its focus changes never reach sd.windows.focusedChanged.
///
/// Main-thread state.
struct AXInstallRetry {
    static let delays: [TimeInterval] = [0.05, 0.1, 0.2, 0.4, 0.8, 1.6, 3.2]

    private var pid: pid_t?
    private var attempt = 0
    private var token: UInt64 = 0

    /// An activation installs for `pid` (nil: teardown). Cancels any pending
    /// retry and restarts the backoff.
    mutating func reset(to pid: pid_t?) {
        self.pid = pid
        attempt = 0
        token &+= 1
    }

    /// An install for `pid` left notifications unregistered. Returns when to
    /// try again, or nil when `pid` is no longer current or the attempts are
    /// spent.
    mutating func failed(pid: pid_t) -> (after: TimeInterval, token: UInt64)? {
        guard pid == self.pid, attempt < Self.delays.count else { return nil }
        let delay = Self.delays[attempt]
        attempt += 1
        token &+= 1
        return (delay, token)
    }

    /// The delay elapsed. True: this retry is still the current one.
    func isDue(pid: pid_t, token: UInt64) -> Bool {
        pid == self.pid && token == self.token
    }
}

// =====================================================================
// MARK: - WindowsAXObserver: per-app AXObserver for window lifecycle
// =====================================================================

// Primary source for `sd.window.created` / `sd.window.destroyed` /
// `sd.window.titleChanged` / `sd.window.moved` / `sd.window.resized` /
// `sd.window.minimized` / `sd.window.deminimized`.
//
/// Leading+trailing throttle keyed per (window, moved|resized). The
/// leading event .emits immediately and arms an 80ms gate; events
/// inside the gate .hold, and the coalescer keeps their `Source` (LAST
/// one wins); the trailing tick hands the held source back via
/// .emitHeld and re-arms, or .closes when the burst went quiet.
///
/// The source is what the caller reads the payload FROM (the window's
/// AXUIElement in production), not the payload itself: a held event is
/// never read, so a drag's in-window callbacks cost no AX round trips —
/// only the edges that actually dispatch do. Pure so the schedule is
/// testable — the caller (WindowsAXObserver.fireFrameBang) owns reads
/// and timers.
struct FrameBangCoalescer<Source> {
    enum Kind: String {
        case moved, resized
        var bangName: String { "sd.window.\(rawValue)" }
    }
    struct Key: Hashable {
        let windowID: CGWindowID
        let kind: Kind
    }
    enum EventAction: Equatable { case emit, hold }
    enum TickAction {
        case emitHeld(Source)
        case close
    }

    static var quietWindow: Double { 0.08 }

    private struct Gate {
        var until: Double
        var held: Source?
    }
    private var gates: [Key: Gate] = [:]

    mutating func onEvent(_ key: Key, now: Double, source: Source) -> EventAction {
        if var gate = gates[key], now < gate.until {
            gate.held = source
            gates[key] = gate
            return .hold
        }
        gates[key] = Gate(until: now + Self.quietWindow, held: nil)
        return .emit
    }

    mutating func onTick(_ key: Key, now: Double) -> TickAction {
        guard var gate = gates[key] else { return .close }
        if let held = gate.held {
            gate.held = nil
            gate.until = now + Self.quietWindow
            gates[key] = gate
            return .emitHeld(held)
        }
        // A tick that fires before the gate's deadline is stale — a
        // fresh leading edge re-armed the gate and scheduled its own
        // tick. Leave the gate for that one.
        if now >= gate.until { gates[key] = nil }
        return .close
    }

    mutating func purge(windowID: CGWindowID) {
        gates = gates.filter { $0.key.windowID != windowID }
    }
}

extension FrameBangCoalescer.TickAction: Equatable where Source: Equatable {}

/// Off-main read schedule for dispatched moved/resized bangs. The frame
/// read goes to the app's AXAppQueues queue, so a stuck app (AX messaging
/// timeout) blocks only its own queue, not the daemon's main thread.
///
/// At most one read in flight per key: a dispatch that lands while one is
/// running parks its source (last wins) and chains once the running read
/// resolves — a hung app accrues one pending read per key, not one per
/// 80ms tick. Each read carries a generation; `purge` (window destroyed)
/// forgets the key, so a result that comes back afterwards resolves to
/// .discard instead of banging a dead window, and can't free a read
/// started after the purge. Pure; the caller owns queues and main hops.
struct FrameBangReads<Source> {
    typealias Key = FrameBangCoalescer<Source>.Key
    struct Start {
        let generation: UInt64
        let source: Source
    }
    enum Resolution {
        /// Deliver the result; start `next` (the parked source) if non-nil.
        case deliver(next: Start?)
        case discard
    }

    private struct Slot {
        var generation: UInt64
        var parked: Source?
    }
    private var inFlight: [Key: Slot] = [:]
    private var nextGeneration: UInt64 = 0

    /// A read to start now, or nil when one is already in flight for the
    /// key (the source is parked and chains on resolve).
    mutating func request(_ key: Key, source: Source) -> Start? {
        if inFlight[key] != nil {
            inFlight[key]?.parked = source
            return nil
        }
        return start(key, source: source)
    }

    mutating func resolved(_ key: Key, generation: UInt64) -> Resolution {
        guard let slot = inFlight[key], slot.generation == generation else { return .discard }
        guard let parked = slot.parked else {
            inFlight[key] = nil
            return .deliver(next: nil)
        }
        return .deliver(next: start(key, source: parked))
    }

    mutating func purge(windowID: CGWindowID) {
        inFlight = inFlight.filter { $0.key.windowID != windowID }
    }

    private mutating func start(_ key: Key, source: Source) -> Start {
        nextGeneration += 1
        inFlight[key] = Slot(generation: nextGeneration, parked: nil)
        return Start(generation: nextGeneration, source: source)
    }
}

extension FrameBangReads.Start: Equatable where Source: Equatable {}
extension FrameBangReads.Resolution: Equatable where Source: Equatable {}

// Per-app `AXObserver` (one per pid) listens for
// `kAXWindowCreatedNotification` on the application AXUIElement. On every
// new window we install a per-window observer for destroy / title / move /
// resize / miniaturize / deminiaturize — exactly the shape Hammerspoon's
// `hs.window.filter` uses (`window_filter.lua` + `axuielement/observer.m`)
// and yabai's `application_observe()` (`src/application.c`).
//
// Why this over a poll: the previous primary was a 1Hz CGWindowList diff
// (`WindowsLifecycleObserver`). CLAUDE.md rule: "Polling is the last
// resort, not the default — look for the event-driven primitive first." A
// live `hs -c` probe of Hammerspoon on the user's macOS 25.5.0 confirms AX
// observers deliver `windowCreated` / `windowDestroyed` reliably within ~1s
// of the action; we want the same.
//
// AX-trust gate: if the daemon hasn't been granted Accessibility, every
// `AXObserverCreate` returns `.cannotComplete` and no events fire. We log
// a clear stderr line at install time so the diagnosis is obvious; we do
// not auto-prompt (matches the rest of stackd's policy).
//
// Coexistence: still feeds the existing `WindowsLifecycleObserver.shared`
// callbacks set up in `AppDelegate.applicationDidFinishLaunching`, so the
// bang fan-out shape stays unchanged. The poll itself stays alive as a
// low-frequency safety backstop with a drift-sensor log when it
// catches an event AX missed.
final class WindowsAXObserver {
    static let shared = WindowsAXObserver()

    private var appObservers: [pid_t: AXAppObserver] = [:]
    private var appTokens: [pid_t: [Token]] = [:]
    // pid → wid → (window AXUIElement we observe + Tokens for the
    // per-window AXObserverAddNotification registrations). We hold the
    // window element so per-window AXObserverRemoveNotification can match
    // the original target when the app terminates or the window dies.
    private var windows: [pid_t: [CGWindowID: (element: AXUIElement, tokens: [Token])]] = [:] {
        didSet { WindowEvents.scheduleFrameInterestRefresh() }
    }

    /// Every wid holding per-window observers, ascending.
    var trackedWIDs: [UInt32] {
        windows.values.flatMap { $0.keys }.map { UInt32($0) }.sorted()
    }
    // Last seen title per (pid, wid). AX's titleChanged callback receives
    // the element but not the previous title; yabai/HS both cache. The
    // `sd.window.titleChanged` bang shape includes `oldTitle`, so stack
    // authors get the same payload from AX as from the polling fallback.
    private var lastTitle: [pid_t: [CGWindowID: String]] = [:]
    // Per-(pid, wid) last AX fire timestamp. The safety poll
    // cross-references this so it only logs "missed by AX" when AX has
    // genuinely been silent for the affected window.
    private(set) var lastAxFire: [CGWindowID: TimeInterval] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    private init() {}

    /// Install per-pid observers for every currently running window-hosting
    /// app, then hook NSWorkspace launch/terminate so we stay in sync as
    /// apps come and go. Idempotent — second call is a no-op.
    func install() {
        guard appObservers.isEmpty else { return }

        // AX trust must be granted for AXObserverCreate to succeed.
        // Prompt: true — every rebuild changes the ad-hoc cdhash and TCC
        // silently invalidates the previous grant, leaving a stale row in
        // System Settings that toggling does NOT re-associate with the new
        // binary. The system prompt is the one flow that binds the grant
        // to the binary actually running; it appears only when trust is
        // missing, so granted sessions never see it.
        let opts: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        if !trusted {
            log("ax: process not trusted for Accessibility — sd.window.* events will not fire (grant in System Settings → Privacy & Security → Accessibility)")
            // We still wire NSWorkspace so a later trust grant + relaunch
            // picks up new apps; per-app AX install will retry until it
            // succeeds via the launch-notification path.
        }

        // Daemon-startup seed: existing windows aren't "newly created"
        // from the user's perspective — they were there before we
        // launched. State replay for windowscape et al. comes via the
        // `sd.windows.all` channel (replayable). So we install observers
        // without firing onCreate for already-present windows.
        //
        // Retried, not one-shot: AX is slammed at daemon boot (every stack
        // probing at once) and AXObserverCreate / AXObserverAddNotification
        // can fail transiently for apps that would succeed seconds later. A
        // single silent failure here would mean EVERY event for that app
        // waits on the 10s safety poll for the daemon's lifetime.
        // fireForExisting stays false on retries too — a retry success
        // can't distinguish pre-daemon windows from during-retry ones, and
        // spurious creates for ancient windows are worse than the poll
        // catching a genuinely-new one late.
        for app in NSWorkspace.shared.runningApplications where shouldObserve(app) {
            installForAppRetry(app: app, delays: WindowsAXObserver.startupRetryDelays, fireForExisting: false)
        }

        let center = NSWorkspace.shared.notificationCenter
        // AX observer registrations and cached elements can go dead across
        // a sleep while their windows live on — no notification tells us.
        // Rebuild the AX layer once the system has settled after wake.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard AXWakeRefresh.shouldRefresh(on: .wake, screenLocked: AXWakeRefresh.screenLocked()) else {
                    log("ax: wake behind the lock screen — AX rebuild waits for unlock")
                    return
                }
                self?.scheduleRefreshAfterWake()
            })
        }
        let dnc = DistributedNotificationCenter.default()
        workspaceTokens.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard AXWakeRefresh.shouldRefresh(on: .unlock, screenLocked: false) else { return }
            self?.scheduleRefreshAfterWake()
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // AX isn't always ready the moment didLaunch fires — yabai's
            // `application.c:93-96` retries on `kAXErrorCannotComplete`
            // after 100ms. Mirror that with a back-off ladder before
            // giving up. AX can also miss the kAXWindowCreatedNotification
            // for windows the app opens during the retry window —
            // `fireForExisting: true` rescues those by firing onCreate for
            // AXWindows present at install time. The 10s safety poll
            // catches whatever still slipped through and logs
            // `missed-by-ax` so a regression here can't hide.
            self?.installForAppRetry(app: app, delays: WindowsAXObserver.launchRetryDelays, fireForExisting: true)
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.uninstallForApp(pid: app.processIdentifier, appName: app.localizedName ?? "")
        })

        WindowDebug.log("ax: installed for \(appObservers.count) running apps (trusted=\(trusted))")
    }

    /// Cross-reference helper for the safety poll. Returns true if AX has
    /// fired for `wid` within `within` seconds — meaning the poll's diff
    /// is a stale read and should be silenced.
    func axFiredRecently(wid: CGWindowID, within: TimeInterval) -> Bool {
        guard let ts = lastAxFire[wid] else { return false }
        return (Date().timeIntervalSince1970 - ts) < within
    }

    /// Destroys already delivered to stacks (AX destroyed notification or
    /// CGS 804), so the safety poll doesn't fire them a second time.
    private var lastDestroyReported: [CGWindowID: TimeInterval] = [:]

    func noteDestroyReported(wid: CGWindowID) {
        lastDestroyReported[wid] = Date().timeIntervalSince1970
    }

    func destroyReportedRecently(wid: CGWindowID, within: TimeInterval) -> Bool {
        guard let ts = lastDestroyReported[wid] else { return false }
        return (Date().timeIntervalSince1970 - ts) < within
    }

    /// Drop lastAxFire entries older than `age`. Called from the safety
    /// poll's tick — the missed-by-ax gate only ever looks back ~12s, so
    /// anything older is dead weight that would otherwise accumulate one
    /// entry per wid for the daemon's lifetime.
    func pruneAxFireLog(olderThan age: TimeInterval) {
        let cutoff = Date().timeIntervalSince1970 - age
        lastAxFire = lastAxFire.filter { $0.value >= cutoff }
        lastDestroyReported = lastDestroyReported.filter { $0.value >= cutoff }
    }

    /// Owning pid for a wid we hold per-window observers on; nil when the
    /// wid isn't (or is no longer) tracked. Used by the CGS 804 destroy
    /// handler for targeted AX-cache invalidation — by the time 804 fires,
    /// the window is gone from CGWindowList so the pid can't be recovered
    /// there.
    func pidFor(wid: CGWindowID) -> pid_t? {
        for (pid, map) in windows where map[wid] != nil { return pid }
        return nil
    }


    // Install retry ladders. Launch path mirrors yabai's
    // kAXErrorCannotComplete retry (application.c:93-96) with tail entries
    // for slow-AX apps (Electron can take >1s to vend AXWindows). Startup
    // path starts slower — the daemon's own boot burst is the usual cause
    // of the first failure, and hammering AX during it makes things worse.
    static let launchRetryDelays:  [TimeInterval] = [0.1, 0.25, 0.5, 1.0, 2.0]
    static let startupRetryDelays: [TimeInterval] = [0.5, 1.0, 2.0]

    // MARK: - App lifecycle

    private func shouldObserve(_ app: NSRunningApplication) -> Bool {
        // .prohibited = background-only (no UI, no AX windows). .regular
        // (Dock+menubar) and .accessory (menubar-only) can still vend
        // AXWindows, so we observe both.
        app.activationPolicy != .prohibited && app.processIdentifier > 0
    }

    private var installRetryGate = AXInstallRetryGate()
    private var wakeRefreshWork: DispatchWorkItem?

    private func scheduleRefreshAfterWake() {
        wakeRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshAfterWake() }
        wakeRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Tear down every AX registration and cached element and install again
    /// from scratch — the daemon-startup path, minus firing creates.
    private func refreshAfterWake() {
        var windowCount = 0
        for pid in Array(appObservers.keys) {
            if let perWindow = windows.removeValue(forKey: pid) {
                windowCount += perWindow.count
                perWindow.values.forEach { $0.tokens.forEach { $0.cancel() } }
            }
            appTokens.removeValue(forKey: pid)?.forEach { $0.cancel() }
            appObservers.removeValue(forKey: pid)
        }
        let appCount = NSWorkspace.shared.runningApplications.filter(shouldObserve).count
        WindowsByID.invalidateAll()
        WindowAddressabilityCache.dropNonPositive()
        for app in NSWorkspace.shared.runningApplications where shouldObserve(app) {
            installForAppRetry(app: app, delays: WindowsAXObserver.startupRetryDelays, fireForExisting: false)
        }
        log("ax: refreshed after wake — \(appCount) apps, \(windowCount) windows torn down")
        AppDelegate.shared?.host?.pumpWindowsListForAllStacks()
        // Installs retry for a few seconds; report what actually came back so
        // a rebuild that attached nothing is visible without debug logging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            let observed = self.windows.values.reduce(0) { $0 + $1.count }
            log("ax: after wake rebuild — \(self.appObservers.count) apps, \(observed) windows observed")
        }
    }

    /// A window re-found without an AX create (safety poll, CGS 1325): make
    /// sure it has live per-window observers. The AX create notification
    /// never fires for a window that already existed, and an entry stored
    /// for an element that went dead (sleep/wake) would otherwise block
    /// re-installation — leaving the window with no moved/resized events.
    func ensurePerWindow(pid: pid_t, wid: CGWindowID) {
        guard let observer = appObservers[pid] else {
            ensureInstalled(pid: pid)
            return
        }
        let fresh = WindowsAXObserver.freshElement(appElement: observer.appElement, wid: wid)
        let decision = PerWindowInstallDecision.decide(
            existing: windows[pid]?[wid]?.element, fresh: fresh, same: { CFEqual($0, $1) })
        guard decision != .keep, let window = fresh else { return }
        if decision == .replace {
            windows[pid]?.removeValue(forKey: wid)?.tokens.forEach { $0.cancel() }
        }
        WindowsByID.invalidateCache(pid: pid, windowID: wid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        log("ax: per-window observers \(decision == .replace ? "replaced" : "attached") pid=\(pid) wid=\(wid) (\(app))")
        installPerWindow(pid: pid, app: app, window: window, firing: false)
    }

    /// The window's element as AX vends it right now — not the cached one.
    private static func freshElement(appElement: AXUIElement, wid: CGWindowID) -> AXUIElement? {
        guard let getWindow = AXShim.getWindow else { return nil }
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return nil }
        return arr.first { el in
            var w: CGWindowID = 0
            return getWindow(el, &w) == .success && w == wid
        }
    }

    /// A window appeared (CGS 1325) for an app we hold no AX observer on —
    /// its install exhausted the launch/startup ladder, typically on a
    /// transient failure while the daemon or the app was busy. Without a
    /// retry the app stays blind for the daemon's lifetime (new windows
    /// only surface via the 10s safety poll). Keyed off window creation, so
    /// windowless helper processes that also fail install never retry.
    func ensureInstalled(pid: pid_t) {
        guard appObservers[pid] == nil,
              installRetryGate.shouldAttempt(pid: pid, now: CFAbsoluteTimeGetCurrent()),
              let app = NSRunningApplication(processIdentifier: pid),
              shouldObserve(app) else { return }
        if installForApp(app: app, fireForExisting: false) {
            log("ax: install recovered pid=\(pid) (\(app.localizedName ?? "?")) on window create")
        }
    }

    private func installForAppRetry(app: NSRunningApplication, delays: [TimeInterval], fireForExisting: Bool) {
        guard shouldObserve(app) else { return }
        if installForApp(app: app, fireForExisting: fireForExisting) { return }
        guard let next = delays.first else {
            // Out of retries. The 10s safety poll still covers this app —
            // events arrive late instead of never — but that degradation
            // must be LOUD (plain log, not WindowDebug): a per-app install
            // failure is otherwise invisible until someone wonders why one
            // app's windows always tile ~10s behind.
            log("ax: install FAILED pid=\(app.processIdentifier) (\(app.localizedName ?? "?")) after all retries — its window events fall back to the 10s safety poll")
            return
        }
        let rest = Array(delays.dropFirst())
        DispatchQueue.main.asyncAfter(deadline: .now() + next) { [weak self] in
            self?.installForAppRetry(app: app, delays: rest, fireForExisting: fireForExisting)
        }
    }

    /// `fireForExisting`: when true, AXWindows already attached to the
    /// app at install time get treated as freshly-created and fire
    /// `onCreate` (the `didLaunchApplication` path uses this — the app
    /// may have opened windows during the AX-install retry window that
    /// we'd otherwise miss). When false, existing windows are seeded
    /// silently (the daemon-startup path uses this — those windows
    /// existed before us and replay through `sd.windows.all` instead).
    @discardableResult
    private func installForApp(app: NSRunningApplication, fireForExisting: Bool) -> Bool {
        let pid = app.processIdentifier
        let name = app.localizedName ?? ""
        if appObservers[pid] != nil { return true }
        guard let observer = AXAppObserver(pid: pid) else {
            WindowDebug.log("ax: install failed pid=\(pid) (\(name)) — AXObserverCreate returned error")
            return false
        }
        var tokens: [Token] = []

        if let t = observer.addWithElement(
            notification: kAXWindowCreatedNotification as String,
            callback: { [weak self] win, _ in self?.onWindowCreated(pid: pid, app: name, window: win) }
        ) {
            tokens.append(t)
        } else {
            // Without windowCreated the app observer is pointless — report
            // failure so the caller's retry ladder gets another shot
            // (AXObserverAddNotification fails with cannotComplete while an
            // app is still booting its AX server). Logged because a silent
            // nil here is the "registration accepted but never fires" class
            // of bug — except worse: the registration didn't even happen.
            WindowDebug.log("ax: addNotification windowCreated FAILED pid=\(pid) (\(name))")
            tokens.forEach { $0.cancel() }
            return false
        }
        if let t = observer.addWithElement(
            notification: kAXFocusedWindowChangedNotification as String,
            callback: { [weak self] win, _ in self?.onFocusedWindowChanged(pid: pid, app: name, window: win) }
        ) {
            tokens.append(t)
        } else {
            // Soft failure — windowCreated still covers lifecycle; we only
            // lose the early-install rescue path for first windows.
            WindowDebug.log("ax: addNotification focusedWindowChanged FAILED pid=\(pid) (\(name))")
        }

        appObservers[pid] = observer
        appTokens[pid] = tokens
        seedExistingWindows(pid: pid, app: name, appElement: observer.appElement, firing: fireForExisting)

        WindowDebug.log("ax: installed pid=\(pid) (\(name)) fireExisting=\(fireForExisting)")
        return true
    }

    private func uninstallForApp(pid: pid_t, appName: String = "") {
        appTokens.removeValue(forKey: pid)?.forEach { $0.cancel() }
        // When an app terminates, AX usually does NOT fire
        // `kAXUIElementDestroyedNotification` for its remaining windows —
        // the process is gone, and any queued AX events go with it. yabai
        // handles this by fanning out window-destroy from the
        // application-terminated path (`event_loop.c` APPLICATION_
        // TERMINATED). Mirror that here so windowscape sees a destroy
        // within the runloop tick of NSWorkspace.didTerminateApplication
        // instead of waiting for the 10s safety poll to notice.
        if let perWindow = windows.removeValue(forKey: pid) {
            let now = Date().timeIntervalSince1970
            for (wid, entry) in perWindow {
                entry.tokens.forEach { $0.cancel() }
                let title = lastTitle[pid]?[wid] ?? ""
                let snap = WindowsLifecycleObserver.Snap(
                    id: Int(wid), pid: Int(pid), app: appName, title: title, frame: .zero
                )
                lastAxFire[wid] = now
                WindowDebug.log("ax: app-terminate destroyed wid=\(wid)")
                WindowsLifecycleObserver.shared.onDestroy?(snap)
            }
        }
        lastTitle.removeValue(forKey: pid)
        appObservers.removeValue(forKey: pid)
        WindowDebug.log("ax: uninstalled pid=\(pid)")
    }

    private func seedExistingWindows(pid: pid_t, app: String, appElement: AXUIElement, firing: Bool) {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &raw) == .success,
              let cf = raw, CFGetTypeID(cf) == CFArrayGetTypeID() else { return }
        let arr = cf as! [AXUIElement]
        for win in arr {
            installPerWindow(pid: pid, app: app, window: win, firing: firing)
        }
    }

    // MARK: - Per-window handlers

    private func onWindowCreated(pid: pid_t, app: String, window: AXUIElement) {
        installPerWindow(pid: pid, app: app, window: window, firing: true)
    }

    // Re-check ladder for windows whose subrole read ERRORED at create time
    // (distinct from "read fine, not standard"). AX timeouts cluster at
    // exactly the moment windows are created — app launch, AX burst — and
    // kAXWindowCreated fires only once, so a dropped window here was
    // permanently invisible to the AX path until the 10s poll rescued it.
    static let subroleRetryDelays: [TimeInterval] = [0.25, 1.0]

    private func installPerWindow(pid: pid_t, app: String, window: AXUIElement, firing: Bool,
                                  subroleRetries: [TimeInterval] = WindowsAXObserver.subroleRetryDelays) {
        guard let observer = appObservers[pid] else { return }
        var w: CGWindowID = 0
        guard let getWindow = AXShim.getWindow, getWindow(window, &w) == .success, w != 0 else { return }
        let wid = w
        if windows[pid]?[wid] != nil { return }

        // Skip non-standard windows (Spotlight overlay, notification banners,
        // popover/sheet helpers, system HUDs). kAXSubrole == kAXStandardWindowSubrole
        // matches the `isStandard` filter `Windows.all()` already applies. Without
        // this gate the AX path fires create/destroy bangs and synthesizes
        // entries into `sd.windows.all` for windows the CGWindowList filter
        // would normally exclude (because their kCGWindowLayer is not 0),
        // and consumers like windowscape end up tiling them.
        //
        // Three-way verdict, not a bool: a subrole read that ERRORS (app
        // still constructing the window, AX timeout under load) must not be
        // conflated with "definitely not standard" — kAXWindowCreated won't
        // re-fire, so a wrong drop here is permanent. Unknown AND
        // un-minimized non-standard both get a bounded recheck before
        // giving up.
        let isMin = axWindowBool(window, kAXMinimizedAttribute as String) ?? false
        let verdict = axSubroleVerdict(window)
        switch verdict {
        case .standard:
            break
        case .nonStandard where isMin:
            // Minimized windows misreport their subrole (see
            // WindowAddressabilityCache.standardVerdict) — a Dock-parked
            // window reading AXDialog is still a real user window. Dropping
            // it here would skip its observers AND its cache seed, leaving
            // the probe to sticky-cache the same bogus non-standard verdict.
            break
        case .nonStandard, .unknown:
            // Neither reading is final. An errored read may be an app still
            // constructing the window or an AX timeout under load; an
            // un-minimized non-standard reading can be transitional (mid
            // minimize/deminimize the subrole still reads AXDialog while
            // AXMinimized has already flipped false). Recheck on the bounded
            // ladder — re-entry re-reads both subrole and AXMinimized; a
            // reading still non-standard once the ladder runs dry is a real
            // dialog/sheet and drops for good.
            let reading = verdict == .unknown ? "unreadable" : "non-standard"
            if let next = subroleRetries.first {
                let rest = Array(subroleRetries.dropFirst())
                WindowDebug.log("ax: subrole \(reading) pid=\(pid) wid=\(wid) — recheck in \(Int(next * 1000))ms")
                DispatchQueue.main.asyncAfter(deadline: .now() + next) { [weak self] in
                    guard let self = self, self.windows[pid]?[wid] == nil else { return }
                    self.installPerWindow(pid: pid, app: app, window: window, firing: firing, subroleRetries: rest)
                }
            } else {
                WindowDebug.log("ax: subrole stayed \(reading) pid=\(pid) wid=\(wid) — dropped after rechecks (10s poll is the backstop)")
            }
            return
        }

        // Seed the addressability cache with the AX-confirmed verdict.
        // Without this, `Windows.all()`'s probe for the brand-new wid lands
        // in the optimism grace (isStandard: false) whenever AX is busy —
        // filtering the window out of the exact snapshot AppDelegate pumps
        // in response to this create.
        WindowAddressabilityCache.confirm(pid: pid, windowID: wid, isStandard: true, isMinimized: isMin)

        let title = axWindowString(window, kAXTitleAttribute as String) ?? ""
        let frame = axWindowFrame(window) ?? .zero
        let snap = WindowsLifecycleObserver.Snap(
            id: Int(wid), pid: Int(pid), app: app, title: title, frame: frame
        )

        var tokens: [Token] = []
        let addPerWindow: (String, @escaping (AXUIElement) -> Void) -> Void = { notif, cb in
            if let t = observer.add(toElement: window, notification: notif, callback: { el, _ in cb(el) }) {
                tokens.append(t)
            } else {
                // Per-CLAUDE.md "verify the listener actually fires": a nil
                // token means AXObserverAddNotification refused — the event
                // type for this window will NEVER fire and only the 10s
                // poll covers it. Must be visible under STACKD_WIN_DEBUG.
                WindowDebug.log("ax: addNotification \(notif) FAILED pid=\(pid) wid=\(wid)")
            }
        }
        addPerWindow(kAXUIElementDestroyedNotification as String) { [weak self] _ in
            self?.onWindowDestroyed(pid: pid, wid: wid, app: app)
        }
        addPerWindow(kAXTitleChangedNotification as String) { [weak self] el in
            self?.onTitleChanged(pid: pid, wid: wid, app: app, window: el)
        }
        addPerWindow(kAXWindowMiniaturizedNotification as String) { [weak self] _ in
            self?.onMinimized(pid: pid, wid: wid)
        }
        addPerWindow(kAXWindowDeminiaturizedNotification as String) { [weak self] _ in
            self?.onDeminimized(pid: pid, wid: wid)
        }
        addPerWindow(kAXWindowMovedNotification as String) { [weak self] el in
            self?.onMoved(pid: pid, wid: wid, window: el)
        }
        addPerWindow(kAXWindowResizedNotification as String) { [weak self] el in
            self?.onResized(pid: pid, wid: wid, window: el)
        }

        windows[pid, default: [:]][wid] = (window, tokens)
        lastTitle[pid, default: [:]][wid] = title

        if firing {
            lastAxFire[wid] = Date().timeIntervalSince1970
            WindowDebug.log("ax: window created pid=\(pid) wid=\(wid) app=\(app) title='\(title)'")
            // No dedup here — WindowLifecycleFanout owns check-and-mark, so
            // a CGS 1325 that beat this AX create dedups at the funnel.
            WindowsLifecycleObserver.shared.onCreate?(snap)
        }
    }

    private func onWindowDestroyed(pid: pid_t, wid: CGWindowID, app: String) {
        let entry = windows[pid]?.removeValue(forKey: wid)
        entry?.tokens.forEach { $0.cancel() }
        let title = lastTitle[pid]?.removeValue(forKey: wid) ?? ""
        lastAxFire[wid] = Date().timeIntervalSince1970
        noteDestroyReported(wid: wid)
        WindowMotionEngine.shared.cancel(windowID: wid)
        FrameLedger.shared.clear(windowID: wid)
        dropFrameBangState(wid: wid)
        titleReads.purge { $0 == wid }
        titleTargets[wid] = nil
        WindowDebug.log("ax: window destroyed pid=\(pid) wid=\(wid)")
        let snap = WindowsLifecycleObserver.Snap(
            id: Int(wid), pid: Int(pid), app: app, title: title, frame: .zero
        )
        WindowsLifecycleObserver.shared.onDestroy?(snap)
    }

    /// The title and frame reads run on the app's AXAppQueues queue, one per
    /// window at a time (AddressabilityReads): a change that lands while a
    /// read is running marks it stale, so its result is dropped and one
    /// fresh read follows. A synchronous read here blocked main for the AX
    /// messaging timeout whenever the app was stuck mid-retitle.
    private struct TitleTarget {
        let pid: pid_t
        let app: String
        let window: AXUIElement
    }
    private var titleReads = AddressabilityReads<CGWindowID>()
    private var titleTargets: [CGWindowID: TitleTarget] = [:]

    private func onTitleChanged(pid: pid_t, wid: CGWindowID, app: String, window: AXUIElement) {
        titleTargets[wid] = TitleTarget(pid: pid, app: app, window: window)
        if let generation = titleReads.request(wid) {
            startTitleRead(wid: wid, generation: generation)
        } else {
            titleReads.markStale { $0 == wid }
        }
    }

    private func startTitleRead(wid: CGWindowID, generation: UInt64) {
        guard let target = titleTargets[wid] else { return }
        AXAppQueues.queue(for: target.pid).async { [weak self] in
            let title = Self.readString(target.window, kAXTitleAttribute as String) ?? ""
            let frame = Self.readWindowFrame(target.window) ?? .zero
            DispatchQueue.main.async {
                self?.titleReadResolved(wid: wid, generation: generation, target: target,
                                        newTitle: title, frame: frame)
            }
        }
    }

    private func titleReadResolved(wid: CGWindowID, generation: UInt64, target: TitleTarget,
                                   newTitle: String, frame: CGRect) {
        switch titleReads.resolved(wid, generation: generation) {
        case .discard:
            return
        case .rerun(let next):
            startTitleRead(wid: wid, generation: next)
            return
        case .apply:
            titleTargets[wid] = nil
        }
        let pid = target.pid, app = target.app
        // Destroyed while the read ran: no title bang for a dead window.
        guard windows[pid]?[wid] != nil else { return }
        let oldTitle = lastTitle[pid]?[wid] ?? ""
        if newTitle == oldTitle { return }
        lastTitle[pid, default: [:]][wid] = newTitle
        let snap = WindowsLifecycleObserver.Snap(
            id: Int(wid), pid: Int(pid), app: app, title: newTitle, frame: frame
        )
        lastAxFire[wid] = Date().timeIntervalSince1970
        WindowDebug.log("ax: window title changed pid=\(pid) wid=\(wid) → '\(newTitle)'")
        WindowsLifecycleObserver.shared.onTitleChange?(snap, oldTitle)
    }

    private func onMinimized(pid: pid_t, wid: CGWindowID) {
        lastAxFire[wid] = Date().timeIntervalSince1970
        // Keep the cached isMinimized live BEFORE pumping — the probe's
        // sticky-success fast path never re-reads AX, so without this the
        // pumped sd.windows.all still carries the pre-minimize value.
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: wid, true)
        WindowDebug.log("ax: window minimized pid=\(pid) wid=\(wid)")
        AppDelegate.shared?.host?.bang(name: "sd.window.minimized", detail: ["id": Int(wid)])
        AppDelegate.shared?.host?.pumpWindowsListForAllStacks()
    }

    private func onDeminimized(pid: pid_t, wid: CGWindowID) {
        lastAxFire[wid] = Date().timeIntervalSince1970
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: wid, false)
        WindowDebug.log("ax: window deminimized pid=\(pid) wid=\(wid)")
        AppDelegate.shared?.host?.bang(name: "sd.window.deminimized", detail: ["id": Int(wid)])
        AppDelegate.shared?.host?.pumpWindowsListForAllStacks()
    }

    private func onMoved(pid: pid_t, wid: CGWindowID, window: AXUIElement) {
        fireFrameBang(.moved, wid: wid, target: FrameBangTarget(pid: pid, window: window))
    }

    private func onResized(pid: pid_t, wid: CGWindowID, window: AXUIElement) {
        fireFrameBang(.resized, wid: wid, target: FrameBangTarget(pid: pid, window: window))
    }

    /// Shared moved/resized dispatch: self-echo classification, then
    /// leading+trailing coalescing.
    ///
    /// While the motion engine is animating a window, its per-tick AX
    /// notifications are swallowed outright — they are our own writes by
    /// construction, and fanning 60–120 bangs/s/window through JSON →
    /// every-stack evaluateJavaScript is pure cost. The settle frame's
    /// trailing echoes arrive after the animation ends (AX lags writes by
    /// up to ~1s) and are delivered with `self: true` via the ledger, so
    /// stacks still observe the final geometry.
    ///
    /// Coalescing (hs.window.filter precedent — HS coalesces these too):
    /// the first event in a burst dispatches immediately so drag brackets
    /// wake promptly; events inside the 80ms quiet window only replace the
    /// held AXUIElement, and the frame is read once the trailing tick
    /// dispatches. A user drag emits (and reads AX) at ~12Hz instead of
    /// on every AX callback.
    ///
    /// The read itself runs on the app's AXAppQueues queue (FrameBangReads
    /// owns the schedule): a synchronous read here blocked main for the
    /// full AX messaging timeout whenever the target app's main thread was
    /// stuck, stalling every overlay and stack push with it.
    private struct FrameBangTarget {
        let pid: pid_t
        let window: AXUIElement
    }
    private typealias FrameBangKey = FrameBangCoalescer<FrameBangTarget>.Key
    private var frameBangCoalescer = FrameBangCoalescer<FrameBangTarget>()
    private var frameBangReads = FrameBangReads<FrameBangTarget>()

    private func fireFrameBang(_ kind: FrameBangCoalescer<FrameBangTarget>.Kind, wid: CGWindowID, target: FrameBangTarget) {
        lastAxFire[wid] = Date().timeIntervalSince1970
        // Checked before the frame read: during an animation every tick
        // echoes back here, and the two AX reads would be discarded anyway.
        if WindowMotionEngine.shared.isAnimating(windowID: wid) {
            WindowDebug.log("ax: \(kind.rawValue) swallowed (animating) wid=\(wid)")
            return
        }
        let key = FrameBangKey(windowID: wid, kind: kind)
        switch frameBangCoalescer.onEvent(key, now: CFAbsoluteTimeGetCurrent(), source: target) {
        case .emit:
            dispatchFrameBang(key, target: target)
            scheduleFrameBangTick(key)
        case .hold:
            break
        }
    }

    /// Starts the off-main frame read, or parks the target behind the one
    /// already in flight for this key.
    private func dispatchFrameBang(_ key: FrameBangKey, target: FrameBangTarget) {
        guard let start = frameBangReads.request(key, source: target) else { return }
        startFrameBangRead(key, start)
    }

    private func startFrameBangRead(_ key: FrameBangKey, _ start: FrameBangReads<FrameBangTarget>.Start) {
        let window = start.source.window
        AXAppQueues.queue(for: start.source.pid).async { [weak self] in
            let frame = WindowsAXObserver.readWindowFrame(window) ?? .zero
            let readAt = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                self?.frameBangReadResolved(key, generation: start.generation, frame: frame, readAt: readAt)
            }
        }
    }

    /// Main thread. Classifies the frame against the ledger as of the
    /// moment it was read, so the echo check sees the frame the bang
    /// carries even when the hop back to main lagged.
    private func frameBangReadResolved(_ key: FrameBangKey, generation: UInt64, frame: CGRect, readAt: Double) {
        guard case .deliver(let next) = frameBangReads.resolved(key, generation: generation) else {
            WindowDebug.log("ax: \(key.kind.rawValue) read dropped (stale) wid=\(key.windowID)")
            return
        }
        if let next = next { startFrameBangRead(key, next) }
        let isSelf = FrameLedger.shared.isSelf(
            windowID: key.windowID, observed: frame, now: readAt
        )
        FrameLedger.shared.observeSize(windowID: key.windowID, size: frame.size)
        WindowDebug.log("ax: window \(key.kind.rawValue) wid=\(key.windowID) self=\(isSelf)")
        AppDelegate.shared?.host?.bang(name: key.kind.bangName, detail: [
            "id": Int(key.windowID),
            "self": isSelf,
            "frame": [
                "x": Int(frame.origin.x), "y": Int(frame.origin.y),
                "w": Int(frame.size.width), "h": Int(frame.size.height)
            ]
        ])
    }

    private func dropFrameBangState(wid: CGWindowID) {
        frameBangCoalescer.purge(windowID: wid)
        frameBangReads.purge(windowID: wid)
    }

    private func scheduleFrameBangTick(_ key: FrameBangKey) {
        // +5ms past the quiet window so the tick lands on the far side of
        // the gate despite main-queue timer jitter.
        DispatchQueue.main.asyncAfter(deadline: .now() + FrameBangCoalescer<FrameBangTarget>.quietWindow + 0.005) { [weak self] in
            guard let self = self else { return }
            switch self.frameBangCoalescer.onTick(key, now: CFAbsoluteTimeGetCurrent()) {
            case .emitHeld(let target):
                self.dispatchFrameBang(key, target: target)
                self.scheduleFrameBangTick(key)
            case .close:
                break
            }
        }
    }

    private func onFocusedWindowChanged(pid: pid_t, app: String, window: AXUIElement) {
        var w: CGWindowID = 0
        guard let getWindow = AXShim.getWindow, getWindow(window, &w) == .success, w != 0 else { return }
        let wid = w
        // If this is a brand-new window we haven't seen, install
        // per-window observers (focusedWindowChanged commonly fires before
        // windowCreated for the first window of a freshly-launched app).
        if windows[pid]?[wid] == nil {
            installPerWindow(pid: pid, app: app, window: window, firing: true)
        }
        WindowDebug.log("ax: focused window pid=\(pid) wid=\(wid)")
        AppDelegate.shared?.host?.bang(name: "sd.window.focused", detail: ["id": Int(wid), "pid": Int(pid), "app": app])
    }

    // MARK: - AX helpers (window-scoped, to avoid colliding with the
    // app-scoped helpers used by FrontmostWindowObserver)

    private func axWindowString(_ el: AXUIElement, _ attr: String) -> String? { Self.readString(el, attr) }

    /// Thread-agnostic: the title path calls it from the app's AX queue.
    private static func readString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Three-way subrole classification — same gate
    /// `WindowAddressabilityCache.probe` applies when enriching
    /// `Windows.all()`, but with the read-error case kept distinct so
    /// `installPerWindow` can retry instead of permanently dropping a
    /// window whose subrole read merely timed out.
    /// `.nonStandard` is a single-sample reading, not a final verdict: mid
    /// minimize/deminimize a real window reads AXDialog, so callers must
    /// recheck (or consult isMinimized) before dropping a window on it.
    private enum SubroleVerdict { case standard, nonStandard, unknown }

    private func axSubroleVerdict(_ el: AXUIElement) -> SubroleVerdict {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &ref) == .success,
              let s = ref as? String else { return .unknown }
        return s == (kAXStandardWindowSubrole as String) ? .standard : .nonStandard
    }

    private func axWindowBool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? Bool
    }

    /// Thread-agnostic (static, touches no observer state): the moved/
    /// resized path calls it from the app's AX queue.
    private func axWindowFrame(_ el: AXUIElement) -> CGRect? { Self.readWindowFrame(el) }

    private static func readWindowFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posCF = posRef, let sizeCF = sizeRef else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(posCF as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sizeCF as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}
