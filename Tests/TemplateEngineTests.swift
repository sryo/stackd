import Foundation
import JavaScriptCore

/// Tests for the JS template engine in `Runtime/api.js`. Exercises the
/// `__sd*` internal functions through JSHarness's JSContext. DOM-coupled
/// behavior (text-node mutation, sd-each cloning, sd-if toggling) needs a
/// fuller harness — not in scope yet. For now we pin the pure-logic layer:
/// placeholder scanning, expression compilation, dependency extraction.
func registerTemplateEngineTests() {
    test("template scan: plain text returns null (no placeholders)") {
        let out = JSHarness.evalString("JSON.stringify(__sdScanPlaceholders('just text, no braces'))")
        try expectEqual(out, "null")
    }

    test("template scan: single placeholder produces one slot, three parts") {
        // parts is [literal-before, null-marker, literal-after]; slot count = 1.
        let probe = JSHarness.evalString("""
        (function() {
          const r = __sdScanPlaceholders('hello {{ x }} world');
          return r.slots.length + ',' + r.parts.length;
        })()
        """)
        try expectEqual(probe, "1,3")
    }

    test("template scan: multiple placeholders accumulate slots") {
        let count = JSHarness.evalString("__sdScanPlaceholders('{{ a }} and {{ b }}').slots.length")
        try expectEqual(count, "2")
    }

    test("template compile: 'sd.battery.percent' deps include the battery signal") {
        // __sdCompilePlaceholder regex-matches each sd.<path> against the
        // known signal table. battery is top-level → one dep entry.
        let depCount = JSHarness.evalString("__sdCompilePlaceholder('sd.battery.percent').deps.length")
        try expectEqual(depCount, "1")
    }

    test("template compile: pure expression with no sd.* refs has empty deps") {
        let depCount = JSHarness.evalString("__sdCompilePlaceholder('1 + 2').deps.length")
        try expectEqual(depCount, "0")
    }

    test("template compile: compiled fn evaluates pure arithmetic") {
        // fn signature: (sd, item, index) -> value. Pure expressions don't
        // reference any of those, so we can pass null/undefined.
        let result = JSHarness.evalString("String(__sdCompilePlaceholder('1 + 2').fn(null, undefined, undefined))")
        try expectEqual(result, "3")
    }

    test("template compile: malformed expression fallback returns empty string") {
        // `new Function` throws on syntax errors → __sdCompilePlaceholder
        // installs a `() => ""` fallback rather than propagating. Important
        // because a single bad template shouldn't crash the whole engine.
        let result = JSHarness.evalString("String(__sdCompilePlaceholder('this is }} not valid').fn(null, undefined, undefined))")
        try expectEqual(result, "")
    }

    test("signal proxy: payload props fall through when signal has no own key") {
        // `sd.appearance.dark` must read `dark` off the channel payload, not
        // off the signal wrapper itself — otherwise every `{{ sd.X.Y }}`
        // template silently evaluates to undefined. Sideswipe + palette
        // shipped with that bug (`data-theme` stuck on 'light'); the fix is a
        // Proxy on signal() that falls through to .value for unknown keys.
        let result = JSHarness.evalString("""
        (function() {
          // Use the real `sd.appearance` channel — push a payload through the
          // exact same path the daemon uses (window.__sd_push).
          window.__sd_push('appearance', { dark: true, accentHex: '#abcdef' });
          return [sd.appearance.dark, sd.appearance.accentHex,
                  typeof sd.appearance.subscribe].join('|');
        })()
        """)
        try expectEqual(result, "true|#abcdef|function")
    }

    test("signal proxy: own keys still shadow payload (RPC methods preserved)") {
        // Object.assign-style extensions on channels (e.g. sd.mouse.warp)
        // must keep working — the Proxy fallback only kicks in when the key
        // is NOT already on the signal wrapper. Regression guard for the
        // sd.mouse.warp / sd.media.nowPlaying.play family of methods.
        let result = JSHarness.evalString("""
        (function() {
          window.__sd_push('mouse', { x: 100, y: 200 });
          // sd.mouse.warp is a function attached via Object.assign — own key.
          const ownKeyWorks = typeof sd.mouse.warp === "function";
          // sd.mouse.x falls through to the payload.
          const payloadFallthrough = sd.mouse.x === 100;
          return ownKeyWorks + "|" + payloadFallthrough;
        })()
        """)
        try expectEqual(result, "true|true")
    }

    test("signal proxy: returns undefined when payload is null (no throw)") {
        // `{{ sd.battery.percent }}` on an empty channel must NOT throw —
        // the engine wraps eval in try/catch, but cleaner to just return
        // undefined so it renders empty without spending a catch.
        let result = JSHarness.evalString("""
        (function() {
          window.__sd_push('battery', null);
          return String(sd.battery.percent);
        })()
        """)
        try expectEqual(result, "undefined")
    }

    test("array channels: default to [] before first daemon push") {
        // Companion to the Proxy fall-through fix. Array channels that pre-fix
        // defaulted to `null` forced every stack to write
        // `(sd.windows.all || []).map(...)` — 9 occurrences across muse,
        // windowscape, bar, etc. Now: `sd.windows.all.map(...)` and
        // `sd.windows.all.length` work pre-push because the underlying value
        // is `[]`, and the Proxy forwards array properties straight through.
        //
        // The six array-typed channels: windowsAll / displays / apps / spaces
        // / usb / camera.
        let result = JSHarness.evalString("""
        (function() {
          // No __sd_push fired — these read the initial value.
          return [
            Array.isArray(sd.windows.all.peek()),
            Array.isArray(sd.display.all.peek()),
            Array.isArray(sd.apps.running.peek()),
            Array.isArray(sd.spaces.all.peek()),
            Array.isArray(sd.usb.peek()),
            Array.isArray(sd.camera.peek())
          ].join(',');
        })()
        """)
        try expectEqual(result, "true,true,true,true,true,true")
    }

    test("array channels: .length and .map work pre-push via Proxy fall-through") {
        // The combo of `[]` default + Proxy fall-through means
        // `sd.usb.length` reads `0` (not throws) on a fresh stack, and
        // `sd.usb.map(fn)` returns `[]` (not throws). This is the shape that
        // lets `{{ sd.usb.length }}` placeholders render `0` instead of empty
        // on first paint. (sd.usb chosen because no other test pushes to it —
        // JSHarness shares context across tests, and DisplayHelpersTests has
        // already populated sd.display.all by the time we get here.)
        let result = JSHarness.evalString("""
        (function() {
          const len = sd.usb.length;
          const mapped = sd.usb.map(d => d.id);
          return len + '|' + Array.isArray(mapped) + '|' + mapped.length;
        })()
        """)
        try expectEqual(result, "0|true|0")
    }
}
