import Foundation

/// Pins the `Channels.all` registry — the single source of truth for every
/// channel the daemon vends. Swift replay (`Bridge.replayState`) and the JS
/// template engine (`window.__sd_channels` → `__sdSignalPaths`) both derive
/// from it, so these snapshots are the same-commit guard: adding, removing,
/// or reordering a channel must update the expectations below.
func registerChannelsRegistryTests() {
    // Lock the snapshot. Adding a Channel means updating this expectation
    // in the SAME commit — the same-commit-test rule from CLAUDE.md
    // applied to the registry itself. Drift between Channels.all and
    // these expected sets means someone touched one without the other.
    let expectedReplayable: [(permission: String, channel: String)] = [
        ("battery",     "battery"),
        ("mouse",       "mouse"),
        ("app",         "frontApp"),
        ("windows",     "focusedWindow"),
        ("windows",     "windowsAll"),
        ("windows",     "windowsChanged"),
        ("appearance",  "appearance"),
        ("input",       "inputLayout"),
        ("net",         "netWifi"),
        ("net",         "netLan"),
        ("net",         "netPath"),
        ("net",         "netThroughput"),
        ("audio",       "audioOutput"),
        ("audio",       "audioInput"),
        ("audio",       "audioProcesses"),
        ("display",     "displays"),
        ("display",     "displaysChanged"),
        ("media",       "media"),
        ("calendar",    "calendarChanged"),
        ("menubar",     "menubarItems"),
        ("menubar",     "menubarChanged"),
        ("pasteboard",  "pasteboard"),
        ("apps",        "apps"),
        ("spaces",      "spaces"),
        ("caffeinate",  "caffeinate"),
        ("sensors",     "sensors"),
        ("location",    "location"),
        ("usb",         "usb"),
        ("camera",      "camera"),
        ("host",        "hostLoad"),
        ("touchdevice", "touchdevice"),
        ("displayLink", "displayLink"),
        ("app",         "appActivated"),
        ("windows",     "focusedChanged"),
        ("windows",     "titleChanged"),
    ]

    test("replayable channels match the pinned (permission, name) list in order") {
        // replayState iteration order is the firing order for newly-ready
        // stacks, so order is part of the contract.
        let actual = Channels.all
            .filter { $0.replayable }
            .map { "\($0.permission):\($0.name)" }
        let want = expectedReplayable.map { "\($0.permission):\($0.channel)" }
        try expectEqual(actual, want)
    }

    // Every template-bindable path. A jsPath dropped from the registry
    // silently breaks `{{ sd.<path> }}` bindings in stacks.
    let expectedJSPaths: Set<String> = [
        "battery", "mouse", "appearance",
        "app.frontmost", "app.activated",
        "windows.focused", "windows.focusedChanged", "windows.titleChanged",
        "windows.all", "windows.changed",
        "input.layout",
        "net.wifi", "net.lan", "net.path", "net.throughput",
        "audio.output", "audio.input", "audio.processes",
        "display.all", "display.changed",
        "media.nowPlaying",
        "pasteboard.changed",
        "apps.running", "apps.changed",
        "spaces.all",
        "caffeinate", "displayLink",
        "host.load", "sensors", "touchdevice", "location", "usb", "camera",
        "calendar.observe",
    ]

    test("registry exposes exactly the pinned jsPath set") {
        let actual = Set(Channels.all.compactMap { $0.jsPath })
        try expectEqual(actual, expectedJSPaths)
    }

    test("every channel's permission is registered in Permissions.all") {
        // A channel gated on an unknown permission can never be granted:
        // the doctor rejects it and inference never adds it.
        for ch in Channels.all {
            try expect(Permissions.all.contains(ch.permission),
                "channel '\(ch.name)' gated on unregistered permission '\(ch.permission)'")
        }
    }

    test("channel names are unique") {
        var seen = Set<String>()
        for ch in Channels.all {
            try expect(!seen.contains(ch.name), "duplicate channel name: \(ch.name)")
            seen.insert(ch.name)
        }
    }

    test("jsPaths are unique") {
        var seen = Set<String>()
        for ch in Channels.all {
            guard let p = ch.jsPath else { continue }
            try expect(!seen.contains(p), "duplicate jsPath: \(p)")
            seen.insert(p)
        }
    }

    test("non-replayable channels are pinned to the expected set") {
        // Pure delta channels never write to lastState so replay would
        // never have anything to push for them. This test pins the
        // current set — if a new delta-only channel ships, update here
        // in the SAME commit. Window-lifecycle bangs (windowCreated etc.)
        // are non-replayable because "a window was just created" has no
        // meaningful state snapshot.
        let nonReplayable = Set(Channels.all.filter { !$0.replayable }.map(\.name))
        let expected: Set<String> = [
            "appsChanged",
            "windowCreated", "windowDestroyed", "windowTitleChanged",
            "windowMoved", "windowResized", "windowResizing",
            "windowMinimized", "windowDeminimized", "windowAnimating",
            "windowReordered", "windowFocusedByMouse",
        ]
        try expectEqual(nonReplayable, expected)
    }

    test("jsBootstrapJSON lists exactly the channels that have a jsPath") {
        // Channels without a template surface (menubarItems, window
        // lifecycle bangs) must not reach the JS bootstrap, or api.js's
        // path resolver warns about a missing sd.<path> binding.
        guard let data = Channels.jsBootstrapJSON.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Expectation(message: "jsBootstrapJSON is not a JSON array of objects")
        }
        let names = entries.compactMap { $0["name"] as? String }
        let want = Channels.all.filter { $0.jsPath != nil }.map(\.name)
        try expectEqual(names, want)
        for e in entries {
            try expect(e["jsPath"] is String && e["permission"] is String,
                "bootstrap entry missing jsPath/permission: \(e)")
        }
    }

    // JS-side round-trip: walk every bootstrapped jsPath against the loaded
    // `sd` object and confirm it resolves to a non-null value. Catches a
    // Channels.all entry naming a JS path that doesn't exist (e.g. a typo
    // like "windows.focusd").
    test("every registered jsPath resolves to a real sd signal") {
        // JSHarness injects window.__sd_channels from Channels.jsBootstrapJSON
        // before loading api.js, mirroring the daemon's document-start script.
        let ctx = JSHarness.context
        let script = """
        (function(){
          var out = {};
          var missing = [];
          for (var i = 0; i < window.__sd_channels.length; i++) {
            var ch = window.__sd_channels[i];
            var cur = sd;
            var parts = ch.jsPath.split('.');
            for (var j = 0; j < parts.length; j++) {
              if (cur == null) break;
              cur = cur[parts[j]];
            }
            if (cur == null) { missing.push(ch.jsPath); continue; }
            out[ch.jsPath] = true;
          }
          return JSON.stringify({ paths: Object.keys(out), missing: missing });
        })();
        """
        guard let result = ctx.evaluateScript(script)?.toString() else {
            throw Expectation(message: "JS evaluation returned nil")
        }
        guard let data = result.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = parsed["paths"] as? [String],
              let missing = parsed["missing"] as? [String] else {
            throw Expectation(message: "JS result not parseable: \(result)")
        }
        try expect(missing.isEmpty,
            "registered jsPaths failed to resolve: \(missing.joined(separator: ", "))")
        try expectEqual(Set(paths), Set(Channels.all.compactMap { $0.jsPath }))
    }
}
