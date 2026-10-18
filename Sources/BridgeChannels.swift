import AppKit

/// Channel producers run by `start(manifest:)`: `startChannels` starts every
/// channel the manifest's permissions grant — each `Channel.feed` through
/// the generic `startChannel` prime-dedupe-push helper, plus the bespoke
/// starters below for channels a single observer + snapshot can't express.
/// `replayState()` stays in Bridge.swift (lifecycle, not a starter).
extension Bridge {
    /// Permission → bespoke starter for channels without a `Channel.feed`:
    /// several channels from one observer (net), deltas computed alongside
    /// the snapshot (display, apps, menubar), or an async snapshot (media).
    /// "app"/"windows" share `startWorkspace` and are handled separately.
    /// The same-commit guard is ChannelStartersTests: every replayable
    /// channel needs a feed or a starter here, or it would compile fine but
    /// silently never replay.
    static let customChannelStarters: [(permission: String, start: (Bridge) -> Void)] = [
        ("net",         { $0.startNetwork() }),
        ("display",     { $0.startDisplay() }),
        ("media",       { $0.startMedia() }),
        ("apps",        { $0.startApps() }),
        ("menubar",     { $0.startMenubarItems() }),
    ]

    /// Starts every channel producer `permissions` grants.
    func startChannels(permissions: [String]) {
        for ch in Channels.all where permissions.contains(ch.permission) {
            guard let feed = ch.feed else { continue }
            startChannel(name: ch.name, observer: feed.observer(), snapshot: feed.snapshot)
        }
        for (permission, start) in Bridge.customChannelStarters where permissions.contains(permission) {
            start(self)
        }
        // Workspace is the one combined starter: "app" and "windows" share
        // an observer with per-permission payload gating, so it can't be a
        // single-permission table row.
        if permissions.contains("app") || permissions.contains("windows") {
            startWorkspace(includeApp: permissions.contains("app"),
                           includeWindows: permissions.contains("windows"))
        }
    }

    /// Wire a snapshot-driven channel: prime once, then refire on every
    /// observer tick. Returning nil from `snapshot` skips the push — matches
    /// the "no data yet" cases (host.load before its first diff, touchdevice
    /// before the first frame, displayLink before vsync).
    ///
    /// Dedupe via lastState[name]: re-emitting an identical JSON blob is
    /// pure overhead (WebKit roundtrip + signal subscribers re-running), and
    /// most observers (Battery, Audio, Display) fire on broad notifications
    /// where the underlying snapshot often hasn't actually changed.
    ///
    /// One observer fire reaches every stack holding the permission; the
    /// snapshot and its JSON are produced once per fire (`perFire`) and
    /// shared, so stacks also see the same reading from snapshots that diff
    /// against their previous call.
    func startChannel(
        name: String,
        observer: RefCountedObserver,
        snapshot: @escaping () -> Any?
    ) {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            // Honor sd.channel.setInterval-set cadence: if a stack asked
            // for a slower fanout on this channel, skip ticks that arrive
            // earlier than the requested interval. Native polling rate is
            // unchanged — this just gates the per-stack JSON + JS round-trip.
            if let interval = self.channelIntervals[name],
               let last = self.lastChannelPushedAt[name],
               Date().timeIntervalSince(last) < interval {
                return
            }
            guard let json = observer.perFire(name, { snapshot().map(Bridge.jsonify) }) else { return }
            guard json != self.lastState[name] else { return }
            self.lastState[name] = json
            self.lastChannelPushedAt[name] = Date()
            self.push(channel: name, json: json)
        }
        pushFn()
        scope.adopt(observer.subscribe(pushFn))
    }

    /// A list snapshot and its JSON, read once per `observer` fan-out under
    /// `key` and shared by every stack the fire reaches — the list-plus-delta
    /// starters' counterpart to `startChannel`'s `perFire`. Each stack still
    /// dedupes and diffs against its own previous list.
    static func sharedList(_ observer: RefCountedObserver, _ key: String,
                           _ read: () -> [[String: Any]]) -> (snapshot: [[String: Any]], json: String) {
        observer.perFire(key) {
            let snapshot = read()
            return (snapshot, Bridge.jsonify(snapshot))
        }
    }

    /// The sd.net.* channels NetworkObserver produces, in push order, each
    /// with its snapshot. sd.net.path derives from the same NWPathMonitor
    /// (no parallel monitor): NetworkObserver caches the latest NWPath, and a
    /// priming fire before any path callback lands sees nil, so the snapshot
    /// is nil — no push — until the first real update arrives. That matches
    /// sd.host.load / sd.touchdevice's "no data yet" handling.
    static let networkSnapshots: [(channel: String, snapshot: () -> Any?)] = [
        ("netLan",  { NetLAN.current() }),
        ("netWifi", { NetWiFi.current() }),
        ("netPath", { NetworkObserver.shared.latestPath.map(NetPath.snapshot(from:)) }),
    ]

    // Multi-channel: one observer (NetworkObserver) feeds three sd.net.*
    // channels. Each branch independently dedupes against lastState so a wifi
    // SSID change doesn't refire lan / path. Keeps its bespoke shape rather
    // than splitting into three observers — the underlying NWPathMonitor is
    // shared.
    func startNetwork(observer: RefCountedObserver = NetworkObserver.shared,
                      snapshots: [(channel: String, snapshot: () -> Any?)] = Bridge.networkSnapshots) {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            for (name, snapshot) in snapshots {
                guard let json = observer.perFire(name, { snapshot().map(Bridge.jsonify) }) else { continue }
                if json == self.lastState[name] { continue }
                self.lastState[name] = json
                self.push(channel: name, json: json)
            }
        }
        pushFn()
        scope.adopt(observer.subscribe(pushFn))
    }

    func startDisplay(observer: RefCountedObserver = DisplayObserver.shared,
                      snapshot readDisplays: @escaping () -> [[String: Any]] = Display.all) {
        // Custom push instead of startChannel so we can compute the
        // sd.displays.changed delta inside the same dedupe branch — same
        // shape as startApps / startWorkspace's windowsAll path.
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let (snapshot, json) = Bridge.sharedList(observer, "displays", readDisplays)
            if json == self.lastState["displays"] { return }
            self.lastState["displays"] = json
            self.push(channel: "displays", json: json)
            let delta = Bridge.displaysDelta(snapshot: snapshot, previous: self.lastDisplaysByID)
            self.lastDisplaysByID = delta.nowByID
            if self.displaysChangedPrimed
                && (!delta.added.isEmpty || !delta.removed.isEmpty || !delta.changed.isEmpty)
            {
                let payload: [String: Any] = [
                    "added":   delta.added,
                    "removed": delta.removed,
                    "changed": delta.changed
                ]
                let deltaJson = Bridge.jsonify(payload)
                self.lastState["displaysChanged"] = deltaJson
                self.push(channel: "displaysChanged", json: deltaJson)
            }
            self.displaysChangedPrimed = true
        }
        pushFn()
        scope.adopt(observer.subscribe(pushFn))
    }

    // Async snapshot: Media.nowPlaying delivers the dict on a background
    // queue, so the dedupe/push hop has to land on main itself. Doesn't fit
    // the synchronous startChannel helper.
    func startMedia() {
        let pushFn: () -> Void = { [weak self] in
            Media.nowPlaying { info in
                guard let self = self else { return }
                let json = info.map { Bridge.jsonify($0) } ?? "null"
                DispatchQueue.main.async {
                    if json == self.lastState["media"] { return }
                    self.lastState["media"] = json
                    self.push(channel: "media", json: json)
                }
            }
        }
        // Initial hydration runs off-main: Media.nowPlaying's MediaRemote-
        // absent path AND the scripted-fallback path both block synchronously
        // (Process.run + waitUntilExit, ~200-600ms cold) on the calling
        // queue. startMedia runs during stack load on main — inline pushFn()
        // would stutter every stack with `media` perm on a Spotify-active
        // session. Hop to utility; the dedupe/push still lands on main.
        DispatchQueue.global(qos: .utility).async { pushFn() }
        scope.adopt(MediaObserver.shared.subscribe(pushFn))
    }

    // sd.menubar.observe — AX-walk the menubar every 2s, diff against the
    // last push, fire on change. AX has no reliable push notification for
    // status-item add/remove, so this is poll-and-diff via startChannel's
    // built-in lastState dedupe. Cadence is tunable per-stack via
    // sd.channel.setInterval. The MenubarItemsObserver keeps a per-PID
    // owner-name cache alive across polls so the NSRunningApplication
    // lookup (the slow part) doesn't repeat for steady-state items.
    func startMenubarItems(observer: RefCountedObserver = MenubarItemsObserver.shared,
                           snapshot readItems: @escaping () -> [[String: Any]] = { MenubarItemsObserver.shared.snapshot() }) {
        // Custom push instead of startChannel so we can compute the
        // sd.menubar.changed delta inside the same dedupe branch —
        // same shape as startDisplay / startApps.
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let (snapshot, json) = Bridge.sharedList(observer, "menubarItems", readItems)
            if json == self.lastState["menubarItems"] { return }
            self.lastState["menubarItems"] = json
            self.push(channel: "menubarItems", json: json)
            let delta = Bridge.menubarDelta(snapshot: snapshot, previous: self.lastMenubarByKey)
            self.lastMenubarByKey = delta.nowByKey
            if self.menubarChangedPrimed
                && (!delta.added.isEmpty || !delta.removed.isEmpty || !delta.changed.isEmpty)
            {
                let payload: [String: Any] = [
                    "added":   delta.added,
                    "removed": delta.removed,
                    "changed": delta.changed
                ]
                let deltaJson = Bridge.jsonify(payload)
                self.lastState["menubarChanged"] = deltaJson
                self.push(channel: "menubarChanged", json: deltaJson)
            }
            self.menubarChangedPrimed = true
        }
        pushFn()
        scope.adopt(observer.subscribe(pushFn))
    }

    // Custom: snapshot has a side effect (computing the apps.changed delta
    // vs lastAppsByBundle) and emits a second channel. Doesn't fit
    // startChannel.
    func startApps(observer: RefCountedObserver = AppsObserver.shared,
                   snapshot readApps: @escaping () -> [[String: Any]] = Apps.running) {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let (snapshot, json) = Bridge.sharedList(observer, "apps", readApps)
            if json == self.lastState["apps"] { return }

            // Delta vs last snapshot before updating the cache. Consumers that
            // only care about transitions (apptimeout, notunes) subscribe to
            // "appsChanged" instead of iterating the full list every tick.
            let d = Bridge.appsDelta(snapshot: snapshot, previous: self.lastAppsByBundle)
            self.lastAppsByBundle = d.nowByBundle
            self.lastState["apps"] = json
            self.push(channel: "apps", json: json)
            // Only emit a non-empty delta — first-tick "every app added" is
            // noise (consumers already get the same data on sd.apps.running).
            if !d.added.isEmpty || !d.removed.isEmpty || !d.changed.isEmpty {
                let delta: [String: Any] = [
                    "added":   d.added,
                    "removed": d.removed,
                    "changed": d.changed
                ]
                self.push(channel: "appsChanged", json: Bridge.jsonify(delta))
            }
        }
        pushFn()
        scope.adopt(observer.subscribe(pushFn))
    }

    // Dual-observer: NSWorkspace activations + per-pid FrontmostWindowObserver
    // for within-app focus/title changes. Emits up to six channels per tick:
    //   - frontApp / focusedWindow / windowsAll (legacy union — backward compat)
    //   - appActivated / focusedChanged / titleChanged (granular per-event-type,
    //     per F15)
    // Gated on includeApp / includeWindows flags. Doesn't fit startChannel's
    // single-channel shape.
    func startWorkspace(includeApp: Bool, includeWindows: Bool) {
        // Per-channel dedupe-and-push helpers. Each granular channel reuses
        // lastState so re-firing the same payload (common when AX nudges
        // multiple times for one focus change) doesn't traverse WebKit
        // unnecessarily.
        let pushAppActivated: () -> Void = { [weak self] in
            guard let self = self, let json = WorkspaceFanout.frontAppJSON() else { return }
            if json == self.lastState["appActivated"] { return }
            self.lastState["appActivated"] = json
            self.push(channel: "appActivated", json: json)
        }
        let pushFocusedChanged: () -> Void = { [weak self] in
            guard let self = self, let json = WorkspaceFanout.focusedJSON() else { return }
            if json == self.lastState["focusedChanged"] { return }
            self.lastState["focusedChanged"] = json
            WindowDebug.log("focus-trace: focusedChanged pushed \(json.prefix(60))")
            self.push(channel: "focusedChanged", json: json)
        }
        let pushTitleChanged: () -> Void = { [weak self] in
            guard let self = self, let w = WorkspaceFanout.focused() else { return }
            // Small payload — id, app, title, pid. Keeps the channel narrow
            // so stacks that only care about title rename don't pay the
            // whole focusedWindow dict on every keystroke in a renaming field.
            let payload: [String: Any] = [
                "id":    w["id"]    as Any? ?? NSNull(),
                "app":   w["app"]   as Any? ?? "",
                "title": w["title"] as Any? ?? "",
                "pid":   w["pid"]   as Any? ?? 0
            ]
            let json = Bridge.jsonify(payload)
            if json == self.lastState["titleChanged"] { return }
            self.lastState["titleChanged"] = json
            self.push(channel: "titleChanged", json: json)
        }
        // Legacy union channel: refire focusedWindow / windowsAll whenever
        // either focusedChanged or titleChanged fires. Stacks still on
        // sd.windows.focused see the same shape they always did.
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            if includeApp, let json = WorkspaceFanout.frontAppJSON() {
                if json != self.lastState["frontApp"] {
                    self.lastState["frontApp"] = json
                    self.push(channel: "frontApp", json: json)
                }
            }
            if includeWindows {
                if let json = WorkspaceFanout.focusedJSON(), json != self.lastState["focusedWindow"] {
                    self.lastState["focusedWindow"] = json
                    self.push(channel: "focusedWindow", json: json)
                }
                let (snapshot, allJson) = WorkspaceFanout.allWindows()
                if allJson != self.lastState["windowsAll"] {
                    self.lastState["windowsAll"] = allJson
                    self.push(channel: "windowsAll", json: allJson)
                    // Compute the diff parallel to sd.apps.changed so
                    // consumers (windowscape / undoclose / framemaster) can
                    // pay diff-size instead of full-list-size. Suppress the
                    // first-tick `added: everything` noise — that's the
                    // same data sd.windows.all already delivered.
                    let delta = Bridge.windowsDelta(snapshot: snapshot, previous: self.lastWindowsByID)
                    self.lastWindowsByID = delta.nowByID
                    if self.windowsChangedPrimed
                        && (!delta.added.isEmpty || !delta.removed.isEmpty || !delta.changed.isEmpty)
                    {
                        let payload: [String: Any] = [
                            "added":   delta.added,
                            "removed": delta.removed,
                            "changed": delta.changed
                        ]
                        let deltaJson = Bridge.jsonify(payload)
                        self.lastState["windowsChanged"] = deltaJson
                        self.push(channel: "windowsChanged", json: deltaJson)
                    }
                    self.windowsChangedPrimed = true
                }
            }
        }
        // Install granular per-event-type callbacks. FrontmostWindowObserver
        // is multi-subscriber: append our handlers, scope-drain the tokens
        // on stack unload. The previous design used single-slot callbacks
        // and the LAST Bridge to set them won — every other stack's
        // focusedChanged / titleChanged silently stopped firing.
        if includeApp {
            scope.adopt(FrontmostWindowObserver.shared.appendAppActivated(pushAppActivated))
        }
        if includeWindows {
            scope.adopt(FrontmostWindowObserver.shared.appendFocusedChanged(pushFocusedChanged))
            scope.adopt(FrontmostWindowObserver.shared.appendTitleChanged(pushTitleChanged))
        }
        // Prime each granular channel so subscribers don't wait for the first
        // AX nudge to see a value.
        if includeApp { pushAppActivated() }
        if includeWindows {
            pushFocusedChanged()
            pushTitleChanged()
        }
        pushFn()
        scope.adopt(FrontmostAppObserver.shared.subscribe(pushFn))
        if includeWindows {
            scope.adopt(FrontmostWindowObserver.shared.subscribe(pushFn))
        }
        // Expose pushFn for the AppDelegate window-lifecycle nudge — see
        // the windowsListPump comment on the property for why this is
        // needed (background window close has no focus-change signal).
        self.windowsListPump = pushFn
    }
}

/// Caches one value per main-queue turn. `turn` is supplied by the caller
/// so the rule stays testable without a run loop.
struct TurnMemo<Value> {
    private var cached: (turn: UInt64, value: Value)?

    mutating func value(turn: UInt64, compute: () -> Value) -> Value {
        if let c = cached, c.turn == turn { return c.value }
        let v = compute()
        cached = (turn, v)
        return v
    }

    /// Use `value` for `turn` instead of computing it.
    mutating func seed(turn: UInt64, value: Value) {
        cached = (turn, value)
    }
}

/// The turn numbers the workspace reads share. One focus change fans out to
/// every stack back to back, and the first read of the window list costs tens
/// of milliseconds, so a turn must outlive a slow read: it ages out only after
/// `maxIdle` with no read starting or finishing, not `maxIdle` after it opened.
/// The main.async that closes the turn can land behind a long queue of other
/// blocks, which is what the idle limit guards against.
struct FanoutTurns {
    private(set) var turn: UInt64 = 0
    private var open = false
    private var lastTouch: CFAbsoluteTime = 0
    let maxIdle: CFAbsoluteTime

    init(maxIdle: CFAbsoluteTime = 0.010) { self.maxIdle = maxIdle }

    /// The turn a read starting at `now` belongs to; `opened` is true when it
    /// opened one, so the caller schedules the close.
    mutating func current(now: CFAbsoluteTime) -> (turn: UInt64, opened: Bool) {
        if open && now - lastTouch > maxIdle {
            turn &+= 1
            lastTouch = now
        }
        if !open {
            open = true
            lastTouch = now
            return (turn, true)
        }
        lastTouch = now
        return (turn, false)
    }

    /// A read that started in this turn finished at `now`.
    mutating func touch(now: CFAbsoluteTime) { lastTouch = now }

    /// The pass that opened the turn is over.
    mutating func close() {
        open = false
        turn &+= 1
    }

    /// Drop the open turn without a read, so the next read starts fresh.
    mutating func advance() {
        open = false
        turn &+= 1
    }
}

/// Workspace state shared by every stack's workspace pushes. One focus
/// change fans out synchronously to each stack's closures (several per
/// stack), so within a single main-queue turn the front app, focused
/// window and window list are read and serialized once instead of per
/// closure per stack. Per-stack dedupe (`lastState`) and deltas stay in
/// each Bridge. Main thread only.
enum WorkspaceFanout {
    private static var turns = FanoutTurns()

    /// The first read in a turn opens it; a main.async closes it, so the
    /// next event's reads start fresh.
    private static func currentTurn() -> UInt64 {
        let (turn, opened) = turns.current(now: CFAbsoluteTimeGetCurrent())
        if opened {
            DispatchQueue.main.async { turns.close() }
        }
        return turn
    }

    /// Runs a read that may be slow, then marks the turn as still in use so
    /// the stacks fanned out after it reuse its result.
    private static func timed<T>(_ read: () -> T) -> T {
        let value = read()
        turns.touch(now: CFAbsoluteTimeGetCurrent())
        return value
    }

    private static var frontAppMemo = TurnMemo<String?>()
    private static var focusedMemo = TurnMemo<(dict: [String: Any]?, json: String)>()
    private static var allMemo = TurnMemo<(snapshot: [[String: Any]], json: String)>()

    static func frontAppJSON() -> String? {
        frontAppMemo.value(turn: currentTurn()) { timed { App.frontmostApp().map(Bridge.jsonify) } }
    }

    /// nil while a confirmed focused-window read is pending (see
    /// FocusedReadSchedule): its delivery pushes the focused channels, so
    /// callers skip instead of blocking main on an AX read.
    static func focused() -> [String: Any]? { focusedEntry()?.dict }
    static func focusedJSON() -> String? { focusedEntry()?.json }

    private static func focusedEntry() -> (dict: [String: Any]?, json: String)? {
        if FrontmostWindowObserver.shared.awaitingFocusedRead { return nil }
        return focusedMemo.value(turn: currentTurn()) {
            timed {
                let w = Windows.focused()
                return (w, w.map(Bridge.jsonify) ?? "null")
            }
        }
    }

    /// A confirmed read resolved: open a fresh turn holding `dict`, so the
    /// fan-out the caller fires next serves it without re-reading AX.
    static func deliverFocused(_ dict: [String: Any]?) {
        turns.advance()
        focusedMemo.seed(turn: currentTurn(), value: (dict, dict.map(Bridge.jsonify) ?? "null"))
    }

    static func allWindows() -> (snapshot: [[String: Any]], json: String) {
        allMemo.value(turn: currentTurn()) {
            timed {
                let snapshot = Windows.all()
                return (snapshot, Bridge.jsonify(snapshot))
            }
        }
    }
}
