import AppKit

/// Channel starters — extracted from Bridge.swift in the A8 breakup round.
/// `channelStarters` is the permission → starter table walked by
/// `start(manifest:)`; `startChannel` is the generic prime-dedupe-push
/// helper; the `startXxx()` methods wire each observer to its sd.* channel.
/// `replayState()` stays in Bridge.swift (lifecycle, not a starter).
///
/// The starters were `private func` in Bridge.swift; `private` doesn't
/// cross files, so they're internal here. The per-channel caches they
/// read/write (`lastState`, the delta caches, `channelIntervals`,
/// `lastChannelPushedAt`, `windowsListPump`) were widened from
/// private/fileprivate to internal in Bridge.swift for the same reason.
extension Bridge {
    /// Permission → channel-starter table walked by `start(manifest:)`.
    /// One row per channel-vending permission ("app"/"windows" share
    /// `startWorkspace` and are handled separately). The same-commit guard
    /// is ChannelStartersTests: every replayable channel in `Channels.all`
    /// must have its permission here (or be workspace-served) — a new
    /// `Channel(...)` without a starter would compile fine but silently
    /// never replay.
    static let channelStarters: [(permission: String, start: (Bridge) -> Void)] = [
        ("battery",     { $0.startBattery() }),
        ("mouse",       { $0.startMouse() }),
        ("appearance",  { $0.startAppearance() }),
        ("input",       { $0.startInput() }),
        ("net",         { $0.startNetwork(); $0.startNetworkThroughput() }),
        ("audio",       { $0.startAudio() }),
        ("display",     { $0.startDisplay() }),
        ("media",       { $0.startMedia() }),
        ("calendar",    { $0.startCalendar() }),
        ("privacy",     { $0.startPrivacy() }),
        ("pasteboard",  { $0.startPasteboard() }),
        ("apps",        { $0.startApps() }),
        ("spaces",      { $0.startSpaces() }),
        ("caffeinate",  { $0.startCaffeinate() }),
        ("sensors",     { $0.startSensors() }),
        ("location",    { $0.startLocation() }),
        ("usb",         { $0.startUSB() }),
        ("camera",      { $0.startCamera() }),
        ("host",        { $0.startHost() }),
        ("touchdevice", { $0.startTouchDevice() }),
        ("displayLink", { $0.startDisplayLink() }),
        ("menubar",     { $0.startMenubarItems() }),
    ]

    /// Wire a snapshot-driven channel: prime once, then refire on every
    /// observer tick. Returning nil from `snapshot` skips the push — matches
    /// the "no data yet" cases (host.load before its first diff, touchdevice
    /// before the first frame, displayLink before vsync).
    ///
    /// Dedupe via lastState[name]: re-emitting an identical JSON blob is
    /// pure overhead (WebKit roundtrip + signal subscribers re-running), and
    /// most observers (Battery, Audio, Display) fire on broad notifications
    /// where the underlying snapshot often hasn't actually changed.
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
            guard let value = snapshot() else { return }
            let json = Bridge.jsonify(value)
            guard json != self.lastState[name] else { return }
            self.lastState[name] = json
            self.lastChannelPushedAt[name] = Date()
            self.push(channel: name, json: json)
        }
        pushFn()
        scope.adopt(observer.subscribe(pushFn))
    }

    func startBattery() {
        startChannel(name: "battery", observer: BatteryObserver.shared) {
            // Additive: existing `percent` / `charging` keys keep their shape
            // and position; the deep IOKit readings (IOPS dict + AppleSmart-
            // Battery IORegistry) follow as optional fields. Each nil-able
            // value goes through `?? NSNull()` so the JSON serializer emits
            // `null` rather than dropping the key — stack authors see the
            // same field shape on desktops (no battery) and on MacBooks
            // alike.
            [
                "percent": Battery.percent(),
                "charging": Battery.isCharging(),
                "cycles": Battery.cycles() as Any? ?? NSNull(),
                "health": Battery.health() as Any? ?? NSNull(),
                "designCapacity": Battery.designCapacity() as Any? ?? NSNull(),
                "maxCapacity": Battery.maxCapacity() as Any? ?? NSNull(),
                "currentCapacity": Battery.currentCapacity() as Any? ?? NSNull(),
                "amperage": Battery.amperage() as Any? ?? NSNull(),
                "voltage": Battery.voltage() as Any? ?? NSNull(),
                "timeRemaining": Battery.timeRemaining() as Any? ?? NSNull(),
                "isFinishingCharge": Battery.isFinishingCharge() as Any? ?? NSNull(),
            ]
        }
    }

    func startMouse() {
        // Truncate to Int for the dedupe — sub-pixel jitter would otherwise
        // push every tick. Matches the original ad-hoc interpolation.
        // Enrich with the containing display so stacks don't reimplement the
        // O(displays) forPoint loop on every tick. Display.forPoint is cheap
        // (NSScreen.screens iteration, no DDC); on a typical 1-2 display
        // setup this is sub-microsecond.
        startChannel(name: "mouse", observer: MouseObserver.shared) {
            let p = Mouse.location()
            var payload: [String: Any] = ["x": Int(p.x), "y": Int(p.y)]
            if let d = Display.forPoint(p) { payload["display"] = d }
            return payload
        }
    }

    func startAppearance() {
        startChannel(name: "appearance", observer: AppearanceObserver.shared) {
            Appearance.current()
        }
    }

    func startInput() {
        startChannel(name: "inputLayout", observer: InputObserver.shared) {
            Input.currentLayout()
        }
    }

    // Multi-channel: one observer (NetworkObserver) feeds three sd.net.*
    // channels. Each branch independently dedupes against lastState so a wifi
    // SSID change doesn't refire lan / path. Keeps its bespoke shape rather
    // than splitting into three observers — the underlying NWPathMonitor is
    // shared.
    func startNetwork() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let lanJson = Bridge.jsonify(NetLAN.current())
            if lanJson != self.lastState["netLan"] {
                self.lastState["netLan"] = lanJson
                self.push(channel: "netLan", json: lanJson)
            }
            let wifiJson = Bridge.jsonify(NetWiFi.current())
            if wifiJson != self.lastState["netWifi"] {
                self.lastState["netWifi"] = wifiJson
                self.push(channel: "netWifi", json: wifiJson)
            }
            // sd.net.path — derived from the same NWPathMonitor (no parallel
            // monitor). NetworkObserver caches the latest NWPath; the priming
            // fire() before any path callback can land sees nil, so skip the
            // push until the first real update arrives. That matches
            // sd.host.load / sd.touchdevice's "no data yet" handling.
            if let path = NetworkObserver.shared.latestPath {
                let pathJson = Bridge.jsonify(NetPath.snapshot(from: path))
                if pathJson != self.lastState["netPath"] {
                    self.lastState["netPath"] = pathJson
                    self.push(channel: "netPath", json: pathJson)
                }
            }
        }
        pushFn()
        scope.adopt(NetworkObserver.shared.subscribe(pushFn))
    }

    // Aggregate throughput across non-loopback interfaces. Replaces the
    // `netstat -ib` setInterval(1s) in bar/items/throughput.js — observer
    // owns the diff math + previous-sample cache so multiple stack
    // subscribers all read the same rate per tick (the previous JS-side
    // version recomputed per stack, drifting its baseline each call).
    func startNetworkThroughput() {
        startChannel(name: "netThroughput", observer: NetworkThroughputObserver.shared) {
            NetworkThroughputObserver.shared.current
        }
    }

    func startAudio() {
        startChannel(name: "audioOutput", observer: AudioObserver.shared) {
            Audio.current()
        }
        // Mirror channel for the default input device. Separate observer
        // because each AudioObserver / AudioInputObserver owns its own
        // listener-block refs and default-device selector — splitting keeps
        // an input device change from re-firing the output channel and vice
        // versa.
        startChannel(name: "audioInput", observer: AudioInputObserver.shared) {
            Audio.currentInput()
        }
        // Per-process audio enumeration (CoreAudio process objects, 14.4+).
        // AudioProcessesObserver is hybrid: event-driven on the process list
        // (add/remove), 1s poll on per-process IsRunningOutput (CoreAudio's
        // listener for that property doesn't fire reliably). Pairs with
        // sd.media.nowPlaying for the rich-active-pill + bare-secondary-
        // pill multi-client bar UI.
        startChannel(name: "audioProcesses", observer: AudioProcessesObserver.shared) {
            AudioProcesses.snapshot()
        }
    }

    func startDisplay() {
        // Custom push instead of startChannel so we can compute the
        // sd.displays.changed delta inside the same dedupe branch — same
        // shape as startApps / startWorkspace's windowsAll path.
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let snapshot = Display.all()
            let json = Bridge.jsonify(snapshot)
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
        scope.adopt(DisplayObserver.shared.subscribe(pushFn))
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

    // Store-change ping channel: EKEventStoreChanged fires when any app
    // (Calendar.app, Reminders, an MDM sync, this daemon's own createEvent)
    // writes to the EventKit database. Apple's docs note the notification's
    // userInfo dict is always empty — there's no delta to ship. We push a
    // monotonic timestamp so the channel's dedupe (lastState string compare)
    // doesn't suppress repeat changes; JS subscribers re-fetch on every
    // signal. Cheap fire-and-forget for stacks that want to keep an agenda
    // view live without polling.
    func startCalendar() {
        startChannel(name: "calendarChanged", observer: CalendarObserver.shared) {
            // Payload is just a fresh timestamp so re-emission dedupe never
            // suppresses a real store change. JS doesn't read the value —
            // the channel is treated as a bell, not a snapshot.
            ["ts": Date().timeIntervalSince1970]
        }
    }

    // Privacy — polled 2s observer pushes the cross-categorical
    // "what's recording" snapshot whenever the active set changes.
    // startChannel's lastState dedupe handles the steady-state case
    // (nothing recording → same payload tick after tick → no push).
    // The snapshot itself reads AVCaptureDevice + CoreAudio property
    // APIs; neither triggers a TCC prompt.
    func startPrivacy() {
        startChannel(name: "privacy", observer: PrivacyObserver.shared) {
            Privacy.recording()
        }
    }

    // sd.menubar.observe — AX-walk the menubar every 2s, diff against the
    // last push, fire on change. AX has no reliable push notification for
    // status-item add/remove, so this is poll-and-diff via startChannel's
    // built-in lastState dedupe. Cadence is tunable per-stack via
    // sd.channel.setInterval. The MenubarItemsObserver keeps a per-PID
    // owner-name cache alive across polls so the NSRunningApplication
    // lookup (the slow part) doesn't repeat for steady-state items.
    func startMenubarItems() {
        // Custom push instead of startChannel so we can compute the
        // sd.menubar.changed delta inside the same dedupe branch —
        // same shape as startDisplay / startApps.
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let snapshot = MenubarItemsObserver.shared.snapshot()
            let json = Bridge.jsonify(snapshot)
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
        scope.adopt(MenubarItemsObserver.shared.subscribe(pushFn))
    }

    func startPasteboard() {
        startChannel(name: "pasteboard", observer: PasteboardObserver.shared) {
            // The signal payload is the current string (or null) — that's what
            // every consumer (CloudPad URL copy, Palette clipboard verbs,
            // Muse paste-at-caret) actually wants.
            let s = Pasteboard.getString() ?? ""
            return ["text": s, "changeCount": Pasteboard.changeCount]
        }
    }

    // Custom: snapshot has a side effect (computing the apps.changed delta
    // vs lastAppsByBundle) and emits a second channel. Doesn't fit
    // startChannel.
    func startApps() {
        let pushFn: () -> Void = { [weak self] in
            guard let self = self else { return }
            let snapshot = Apps.running()
            let json = Bridge.jsonify(snapshot)
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
        scope.adopt(AppsObserver.shared.subscribe(pushFn))
    }

    func startSpaces() {
        startChannel(name: "spaces", observer: SpacesObserver.shared) {
            Spaces.all()
        }
    }

    func startCaffeinate() {
        startChannel(name: "caffeinate", observer: CaffeinateObserver.shared) {
            Caffeinate.snapshot()
        }
    }

    func startDisplayLink() {
        // First-tick nil (vsync hasn't landed yet) → snapshot returns nil →
        // startChannel skips the push.
        startChannel(name: "displayLink", observer: DisplayLinkObserver.shared) {
            DisplayLink.snapshot()
        }
    }

    func startSensors() {
        startChannel(name: "sensors", observer: SensorsObserver.shared) {
            Sensors.snapshot()
        }
    }

    func startLocation() {
        // snapshot() is nil until authorization + first fix; emit an explicit
        // "null" so the JS channel sees that initial state instead of staying
        // un-fired. Wrap in [NSNull()] sentinel to flow through jsonify as
        // "null".
        startChannel(name: "location", observer: LocationObserver.shared) {
            return Location.snapshot() ?? NSNull()
        }
    }

    func startUSB() {
        startChannel(name: "usb", observer: USBObserver.shared) {
            USB.snapshot()
        }
    }

    func startCamera() {
        startChannel(name: "camera", observer: CameraObserver.shared) {
            Camera.snapshot()
        }
    }

    func startHost() {
        // First tick returns nil — CPU fractions need a prior sample to diff
        // against. startChannel skips the push; the next 2s tick has the value.
        startChannel(name: "hostLoad", observer: HostObserver.shared) {
            Host.loadSnapshot()
        }
    }

    func startTouchDevice() {
        // No-frame state (untouched trackpad before first event) → nil →
        // startChannel skips. JS sees the channel stay at its null initial.
        startChannel(name: "touchdevice", observer: TouchDeviceObserver.shared) {
            TouchDevice.snapshot()
        }
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
            guard let self = self, let app = App.frontmostApp() else { return }
            let json = Bridge.jsonify(app)
            if json == self.lastState["appActivated"] { return }
            self.lastState["appActivated"] = json
            self.push(channel: "appActivated", json: json)
        }
        let pushFocusedChanged: () -> Void = { [weak self] in
            guard let self = self else { return }
            let json = Windows.focused().map(Bridge.jsonify) ?? "null"
            if json == self.lastState["focusedChanged"] { return }
            self.lastState["focusedChanged"] = json
            self.push(channel: "focusedChanged", json: json)
        }
        let pushTitleChanged: () -> Void = { [weak self] in
            guard let self = self, let w = Windows.focused() else { return }
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
            if includeApp, let app = App.frontmostApp() {
                let json = Bridge.jsonify(app)
                if json != self.lastState["frontApp"] {
                    self.lastState["frontApp"] = json
                    self.push(channel: "frontApp", json: json)
                }
            }
            if includeWindows {
                let json = Windows.focused().map(Bridge.jsonify) ?? "null"
                if json != self.lastState["focusedWindow"] {
                    self.lastState["focusedWindow"] = json
                    self.push(channel: "focusedWindow", json: json)
                }
                let snapshot = Windows.all()
                let allJson = Bridge.jsonify(snapshot)
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
