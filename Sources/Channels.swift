import Foundation

/// Single source of truth for every channel the daemon vends.
///
/// Two parallel tables both derive from this one list so they can't drift:
///
///   1. `Bridge.replayTable` (Swift) — `(permission, channel)` tuples
///      driving the "ready" RPC's snapshot replay. For each tuple where the
///      stack has the permission AND `lastState[channel]` exists, push the
///      cached JSON so a newly-ready stack starts with current state.
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

    init(name: String, jsPath: String?, permission: String, replayable: Bool = true) {
        self.name = name
        self.jsPath = jsPath
        self.permission = permission
        self.replayable = replayable
    }
}

enum Channels {
    /// Every channel the daemon vends, in `replayState` iteration order
    /// (matters for the initial state firing order on stack ready).
    ///
    /// When adding a new channel:
    ///   1. Add a `Channel(...)` entry below.
    ///   2. Use `lastState[name] = json` + `push(channel: name, json: json)`
    ///      in the producing `startXxx()` — same shape as every existing
    ///      channel.
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
        Channel(name: "battery",         jsPath: "battery",            permission: "battery"),
        Channel(name: "mouse",           jsPath: "mouse",              permission: "mouse"),
        Channel(name: "frontApp",        jsPath: "app.frontmost",      permission: "app"),
        Channel(name: "focusedWindow",   jsPath: "windows.focused",    permission: "windows"),
        Channel(name: "windowsAll",      jsPath: "windows.all",        permission: "windows"),
        Channel(name: "windowsChanged",  jsPath: "windows.changed",    permission: "windows"),
        Channel(name: "appearance",      jsPath: "appearance",         permission: "appearance"),
        Channel(name: "inputLayout",     jsPath: "input.layout",       permission: "input"),
        Channel(name: "netWifi",         jsPath: "net.wifi",           permission: "net"),
        Channel(name: "netLan",          jsPath: "net.lan",            permission: "net"),
        Channel(name: "netPath",         jsPath: "net.path",           permission: "net"),
        Channel(name: "netThroughput",   jsPath: "net.throughput",     permission: "net"),
        Channel(name: "audioOutput",     jsPath: "audio.output",       permission: "audio"),
        Channel(name: "audioInput",      jsPath: "audio.input",        permission: "audio"),
        Channel(name: "audioProcesses",  jsPath: "audio.processes",    permission: "audio"),
        Channel(name: "displays",        jsPath: "display.all",        permission: "display"),
        Channel(name: "displaysChanged", jsPath: "display.changed",    permission: "display"),
        Channel(name: "media",           jsPath: "media.nowPlaying",   permission: "media"),
        Channel(name: "calendarChanged", jsPath: "calendar.observe",   permission: "calendar"),
        // menubarItems / menubarChanged have no template surface — stacks
        // subscribe via sd.menubar.items / sd.menubar.changed in JS but
        // there's no {{ sd.menubar.x }} placeholder shape today.
        Channel(name: "menubarItems",    jsPath: nil,                  permission: "menubar"),
        Channel(name: "menubarChanged",  jsPath: nil,                  permission: "menubar"),
        Channel(name: "pasteboard",      jsPath: "pasteboard.changed", permission: "pasteboard"),
        Channel(name: "apps",            jsPath: "apps.running",       permission: "apps"),
        Channel(name: "spaces",          jsPath: "spaces.all",         permission: "spaces"),
        Channel(name: "caffeinate",      jsPath: "caffeinate",         permission: "caffeinate"),
        Channel(name: "sensors",         jsPath: "sensors",            permission: "sensors"),
        Channel(name: "location",        jsPath: "location",           permission: "location"),
        Channel(name: "usb",             jsPath: "usb",                permission: "usb"),
        Channel(name: "camera",          jsPath: "camera",             permission: "camera"),
        Channel(name: "hostLoad",        jsPath: "host.load",          permission: "host"),
        Channel(name: "touchdevice",     jsPath: "touchdevice",        permission: "touchdevice"),
        Channel(name: "displayLink",     jsPath: "displayLink",        permission: "displayLink"),
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
        Channel(name: "windowMinimized",     jsPath: nil, permission: "windows", replayable: false),
        Channel(name: "windowDeminimized",   jsPath: nil, permission: "windows", replayable: false),
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
}
