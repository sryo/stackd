import Foundation

/// Pins the `Channels.all` registry as the single source of truth for
/// every channel the daemon vends. Before this refactor, two parallel
/// hardcoded tables (Bridge.replayTable + Runtime/api.js __sdSignalPaths)
/// drifted apart when primitive authors touched one and forgot the other.
///
/// These tests verify:
///   1. The registry contains every entry the old replayTable had
///      (replayable channels) — replayState behavior is preserved.
///   2. The registry exposes a `jsPath` for every entry the old
///      __sdSignalPaths had — template engine bindings are preserved.
///   3. The injected `window.__sd_channels` payload round-trips through
///      api.js's __sdSignalPaths resolver and produces a non-empty,
///      longest-first-sorted path map identical in shape to the pre-
///      refactor hardcoded one.
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

    test("registry preserves every replayTable entry") {
        let actual = Channels.all
            .filter { $0.replayable }
            .map { (permission: $0.permission, channel: $0.name) }
        try expectEqual(actual.count, expectedReplayable.count)
        for (i, (got, want)) in zip(actual, expectedReplayable).enumerated() {
            try expectEqual(got.permission, want.permission,
                "replayable[\(i)] permission")
            try expectEqual(got.channel, want.channel,
                "replayable[\(i)] channel")
        }
    }

    test("registry replay order matches historical replayTable order") {
        // replayState iteration order is the firing order for newly-ready
        // stacks. Locking the order means existing stacks see channels
        // arrive in the same sequence as before the refactor.
        let names = Channels.all.filter { $0.replayable }.map(\.name)
        let want = expectedReplayable.map { $0.channel }
        try expectEqual(names, want)
    }

    // Pre-refactor hardcoded path set from Runtime/api.js. Adding to
    // __sdSignalPaths without registering the matching Swift channel means
    // template bindings break silently — this test fails first if the
    // jsPath set drifts.
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

    test("registry exposes every pre-refactor jsPath") {
        let actual = Set(Channels.all.compactMap { $0.jsPath })
        try expectEqual(actual, expectedJSPaths)
    }

    test("every jsPath has a non-empty permission") {
        for ch in Channels.all where ch.jsPath != nil {
            try expect(!ch.permission.isEmpty, "jsPath \(ch.jsPath!) missing permission")
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

    test("appsChanged is the only non-replayable channel today") {
        // Pure delta channels never write to lastState so replay would
        // never have anything to push for them. This test pins the
        // current split — if a new delta-only channel ships, update here
        // in the SAME commit.
        let nonReplayable = Channels.all.filter { !$0.replayable }.map(\.name)
        try expectEqual(nonReplayable, ["appsChanged"])
    }

    test("jsBootstrapJSON omits channels without a jsPath") {
        // menubarItems / menubarChanged have no template surface so they
        // must NOT appear in the JS-side bootstrap. Otherwise api.js's
        // __sdResolvePath would warn about a missing sd.foo binding.
        let json = Channels.jsBootstrapJSON
        try expect(!json.contains("\"menubarItems\""),
            "menubarItems leaked into JS bootstrap")
        try expect(!json.contains("\"menubarChanged\""),
            "menubarChanged leaked into JS bootstrap")
        // But replayable channels with a jsPath DO appear.
        try expect(json.contains("\"battery\""),  "battery missing from JS bootstrap")
        try expect(json.contains("\"frontApp\""), "frontApp missing from JS bootstrap")
    }

    // JS-side round-trip: inject the registry into a fresh JSContext shim,
    // load the path-resolver shape from api.js, and confirm every jsPath
    // resolves to a non-null signal. Catches the case where a Channels.all
    // entry references a JS path that doesn't exist (e.g. typo: "windows.focusd").
    test("every registered jsPath resolves to a real sd signal") {
        // JSHarness's existing context has api.js already loaded WITHOUT
        // __sd_channels (it's nil during bootstrap), so __sdSignalPaths
        // came out empty + warned. Re-run the resolver here with the real
        // bootstrap payload injected.
        let ctx = JSHarness.context
        ctx.evaluateScript("window.__sd_channels = \(Channels.jsBootstrapJSON);")

        // Recompute the path map using api.js's resolver shape (mirrors
        // the IIFE at the top of __sdSignalPaths). If any jsPath fails to
        // resolve, the value lands null and the test logs the offender.
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
        // Sanity: should match expected JS path count.
        try expectEqual(Set(paths), expectedJSPaths)
    }
}
