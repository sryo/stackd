import Foundation

/// Single source of truth for every channel the daemon vends.
///
/// Two parallel tables both derive from this one list so they can't drift:
///
///   1. `Bridge.replayState()` (Swift) — the "ready" RPC's snapshot replay.
///      For each channel where the stack has the permission AND
///      `lastState[name]` exists, push the cached JSON so a newly-ready
///      stack starts with current state.
///
///   2. `__sdSignalPaths` (Runtime/api.js) — dotted JS path → `sd.<x>`
///      signal map. The template engine's `__sdCompilePlaceholder` regex-
///      matches each `sd.<path>` against the longest-first sorted key set
///      to subscribe placeholder expressions to the right channels.
///
/// Both derive from `Channels.all` below. Adding a new channel is a
/// single-place edit: drop a `Channel(…)` entry in this file. Both the
/// Swift replay path and the JS template-engine path pick it up — no
/// chance of half-wiring it.
///
/// The `jsPath` is optional because a few channels exist daemon-side
/// without a templatable JS surface (e.g. `menubarItems` / `menubarChanged`
/// are subscribed via explicit `sd.menubar.subscribe(...)` rather than
/// `{{ sd.menubar.x }}` placeholders). `replayable` defaults to true and
/// is set false for pure delta channels (`appsChanged`) that never write
/// to `lastState` and therefore have nothing to replay.
///
/// A channel with a `feed` is produced by `Bridge.start(manifest:)` itself:
/// it subscribes the feed's observer for each stack holding the permission
/// and pushes the snapshot whenever its JSON changes. Channels without one
/// come from a bespoke starter (`Bridge.customChannelStarters`, the
/// workspace starter) or are events pushed from elsewhere.
struct Channel {
    /// The channel name as it appears in `push(channel:json:)` and the
    /// `lastState` cache key. Stable contract — the bridge writes
    /// `lastState[name]` and the JS side dispatches via `window.__sd_push(name, …)`.
    let name: String

    /// The dotted JS path under `sd.` that the template engine resolves
    /// for `{{ sd.<jsPath>.field }}` placeholders. nil when the channel
    /// has no template surface (typed RPC subscription only).
    let jsPath: String?

    /// The manifest permission gating subscription to this channel.
    /// `replayState` filters by `permissions.contains(permission)` before
    /// pushing.
    let permission: String

    /// When true, `replayState()` looks up `lastState[name]` and pushes
    /// the cached snapshot on stack ready. When false, the channel is
    /// pure delta — no snapshot is cached, so there's nothing to replay.
    /// Set false for `appsChanged`-style channels whose payload only makes
    /// sense as an event, not a state.
    let replayable: Bool

    /// The observer + snapshot pair that produces this channel, or nil when
    /// something else pushes it.
    let feed: ChannelFeed?

    init(name: String, jsPath: String?, permission: String, replayable: Bool = true,
         feed: ChannelFeed? = nil) {
        self.name = name
        self.jsPath = jsPath
        self.permission = permission
        self.replayable = replayable
        self.feed = feed
    }
}

/// A snapshot-driven channel source: every `observer` tick re-reads
/// `snapshot`, and the bridge pushes it when its JSON changed. A nil
/// snapshot means "no data yet" and skips the push.
struct ChannelFeed {
    /// Resolved on first start, so building the registry never wakes an
    /// observer singleton.
    let observer: () -> RefCountedObserver
    let snapshot: () -> Any?

    static func observe(_ observer: @autoclosure @escaping () -> RefCountedObserver,
                        _ snapshot: @escaping () -> Any?) -> ChannelFeed {
        ChannelFeed(observer: observer, snapshot: snapshot)
    }
}

enum Channels {
    /// Every channel the daemon vends, in `replayState` iteration order
    /// (matters for the initial state firing order on stack ready).
    ///
    /// When adding a new channel:
    ///   1. Add a `Channel(...)` entry below.
    ///   2. Give it a `feed:` when one observer + one snapshot produce it;
    ///      otherwise push it from a starter with `lastState[name] = json` +
    ///      `push(channel: name, json: json)`.
    ///   3. If templates should be able to bind to `sd.<jsPath>.x`, set a
    ///      non-nil `jsPath`. Pure RPC channels (no template surface) pass
    ///      `jsPath: nil`.
    ///   4. The `ChannelsRegistryTests` snapshot will fail if the new entry
    ///      breaks the JS-side mirror; that's the same-commit guard.
    ///
    /// Mirrors the doctor-allowlist rule: add the registry entry in the
    /// SAME commit as the producing channel. Same-commit-or-test-fails is
    /// stronger than "remember to touch both places" — the test catches
    /// half-wired adds at CI time.
    static let all: [Channel] = [
        Channel(name: "battery",         jsPath: "battery",            permission: "battery",
                feed: .observe(BatteryObserver.shared, batterySnapshot)),
        Channel(name: "mouse",           jsPath: "mouse",              permission: "mouse",
                feed: .observe(MouseObserver.shared, mouseSnapshot)),
        Channel(name: "frontApp",        jsPath: "app.frontmost",      permission: "app"),
        Channel(name: "focusedWindow",   jsPath: "windows.focused",    permission: "windows"),
        Channel(name: "windowsAll",      jsPath: "windows.all",        permission: "windows"),
        Channel(name: "windowsChanged",  jsPath: "windows.changed",    permission: "windows"),
        Channel(name: "appearance",      jsPath: "appearance",         permission: "appearance",
                feed: .observe(AppearanceObserver.shared) { Appearance.current() }),
        Channel(name: "inputLayout",     jsPath: "input.layout",       permission: "input",
                feed: .observe(InputObserver.shared) { Input.currentLayout() }),
        Channel(name: "netWifi",         jsPath: "net.wifi",           permission: "net"),
        Channel(name: "netLan",          jsPath: "net.lan",            permission: "net"),
        Channel(name: "netPath",         jsPath: "net.path",           permission: "net"),
        // Aggregate rate across non-loopback interfaces; the observer owns
        // the diff math so every stack reads the same rate per tick.
        Channel(name: "netThroughput",   jsPath: "net.throughput",     permission: "net",
                feed: .observe(NetworkThroughputObserver.shared) { NetworkThroughputObserver.shared.current }),
        // Output, input and per-process audio each have their own observer,
        // so a change on one doesn't refire the others.
        Channel(name: "audioOutput",     jsPath: "audio.output",       permission: "audio",
                feed: .observe(AudioObserver.shared) { Audio.current() }),
        Channel(name: "audioInput",      jsPath: "audio.input",        permission: "audio",
                feed: .observe(AudioInputObserver.shared) { Audio.currentInput() }),
        Channel(name: "audioProcesses",  jsPath: "audio.processes",    permission: "audio",
                feed: .observe(AudioProcessesObserver.shared) { AudioProcesses.snapshot() }),
        Channel(name: "displays",        jsPath: "display.all",        permission: "display"),
        Channel(name: "displaysChanged", jsPath: "display.changed",    permission: "display"),
        Channel(name: "media",           jsPath: "media.nowPlaying",   permission: "media"),
        Channel(name: "calendarChanged", jsPath: "calendar.observe",   permission: "calendar",
                feed: .observe(CalendarObserver.shared, calendarBell)),
        // "What's recording" across camera / microphone; the steady state
        // (nothing recording) dedupes to no push.
        Channel(name: "privacy",         jsPath: "privacy.observe",    permission: "privacy",
                feed: .observe(PrivacyObserver.shared) { Privacy.recording() }),
        // menubarItems / menubarChanged have no template surface — stacks
        // subscribe via sd.menubar.items / sd.menubar.changed in JS but
        // there's no {{ sd.menubar.x }} placeholder shape today.
        Channel(name: "menubarItems",    jsPath: nil,                  permission: "menubar"),
        Channel(name: "menubarChanged",  jsPath: nil,                  permission: "menubar"),
        Channel(name: "pasteboard",      jsPath: "pasteboard.changed", permission: "pasteboard",
                feed: .observe(PasteboardObserver.shared, pasteboardSnapshot)),
        Channel(name: "apps",            jsPath: "apps.running",       permission: "apps"),
        Channel(name: "spaces",          jsPath: "spaces.all",         permission: "spaces",
                feed: .observe(SpacesObserver.shared) { Spaces.all() }),
        Channel(name: "caffeinate",      jsPath: "caffeinate",         permission: "caffeinate",
                feed: .observe(CaffeinateObserver.shared) { Caffeinate.snapshot() }),
        Channel(name: "sensors",         jsPath: "sensors",            permission: "sensors",
                feed: .observe(SensorsObserver.shared) { Sensors.snapshot() }),
        // nil until authorization + first fix; pushed as an explicit null so
        // the channel fires its initial state instead of staying un-fired.
        Channel(name: "location",        jsPath: "location",           permission: "location",
                feed: .observe(LocationObserver.shared) { Location.snapshot() ?? NSNull() }),
        Channel(name: "usb",             jsPath: "usb",                permission: "usb",
                feed: .observe(USBObserver.shared) { USB.snapshot() }),
        Channel(name: "camera",          jsPath: "camera",             permission: "camera",
                feed: .observe(CameraObserver.shared) { Camera.snapshot() }),
        // nil on the first tick: CPU fractions need a prior sample to diff.
        Channel(name: "hostLoad",        jsPath: "host.load",          permission: "host",
                feed: .observe(HostObserver.shared) { Host.loadSnapshot() }),
        // nil until the trackpad reports its first frame.
        Channel(name: "touchdevice",     jsPath: "touchdevice",        permission: "touchdevice",
                feed: .observe(TouchDeviceObserver.shared) { TouchDevice.snapshot() }),
        // nil until the first vsync lands.
        Channel(name: "displayLink",     jsPath: "displayLink",        permission: "displayLink",
                feed: .observe(DisplayLinkObserver.shared) { DisplayLink.snapshot() }),
        // Granular per-event-type channels. Same permissions as the union
        // focusedWindow / frontApp channels so stacks declaring "app" /
        // "windows" pick them up.
        Channel(name: "appActivated",    jsPath: "app.activated",         permission: "app"),
        Channel(name: "focusedChanged",  jsPath: "windows.focusedChanged",permission: "windows"),
        Channel(name: "titleChanged",    jsPath: "windows.titleChanged",  permission: "windows"),
        // Pure delta channel — no snapshot is cached, so replay skips it.
        // Included here so the JS-side __sdSignalPaths still picks up the
        // sd.apps.changed binding and template authors can subscribe via
        // {{ sd.apps.changed.added.length }} etc.
        Channel(name: "appsChanged",     jsPath: "apps.changed",       permission: "apps", replayable: false),
        // Window lifecycle bangs (sd.window.created etc.) are pure-event
        // channels, dispatched via host.bang → onBang_… in JS, not via
        // signal paths. Registered here so the same-commit
        // PermissionsRegistryTests / ChannelsRegistryTests guard catches
        // any new bang that doesn't declare its permission, and so a
        // future template surface for window events (e.g. {{ sd.windows
        // .created.app }}) can hang a jsPath off the same entry.
        Channel(name: "windowCreated",       jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowDestroyed",     jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowTitleChanged",  jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowMoved",         jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowResized",       jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowResizing",      jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowMinimized",     jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowDeminimized",   jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowAnimating",     jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowReordered",     jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowFocusedByMouse", jsPath: nil, permission: "windows", replayable: false),
    ]

    /// JSON payload injected as `window.__sd_channels` at document start so
    /// `Runtime/api.js` can build its `__sdSignalPaths` map from the same
    /// list this file owns. Built once, cached forever — the registry is
    /// static.
    static let jsBootstrapJSON: String = {
        let entries: [[String: Any]] = all.compactMap { ch in
            guard let path = ch.jsPath else { return nil }
            return ["name": ch.name, "jsPath": path, "permission": ch.permission]
        }
        return Bridge.jsonify(entries)
    }()

    /// `percent` / `charging` plus the deep IOKit readings. Missing readings
    /// are `null` rather than absent, so desktops (no battery) and laptops
    /// share one field shape.
    private static func batterySnapshot() -> Any? {
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

    /// Whole-pixel position (sub-pixel jitter would push every tick) plus
    /// the display under the cursor, so stacks don't redo the per-display
    /// hit test on every tick.
    private static func mouseSnapshot() -> Any? {
        let p = Mouse.location()
        var payload: [String: Any] = ["x": Int(p.x), "y": Int(p.y)]
        if let d = Display.forPoint(p) { payload["display"] = d }
        return payload
    }

    /// EventKit's change notification carries no delta, so the channel is a
    /// bell: a fresh timestamp keeps the dedupe from swallowing a repeat
    /// change, and subscribers re-fetch.
    private static func calendarBell() -> Any? {
        ["ts": Date().timeIntervalSince1970]
    }

    private static func pasteboardSnapshot() -> Any? {
        ["text": Pasteboard.getString() ?? "", "changeCount": Pasteboard.changeCount]
    }
}
