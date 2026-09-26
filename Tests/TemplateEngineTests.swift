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

    test("template scan: single placeholder splits into literal, slot marker, literal") {
        let probe = JSHarness.evalString("""
        (function() {
          const r = __sdScanPlaceholders('hello {{ x }} world');
          return r.slots.length + '|' + JSON.stringify(r.parts);
        })()
        """)
        try expectEqual(probe, "1|[\"hello \",null,\" world\"]")
    }

    test("template scan: multiple placeholders accumulate slots and union their deps") {
        let probe = JSHarness.evalString("""
        (function() {
          const r = __sdScanPlaceholders('{{ sd.battery.percent }} and {{ sd.battery.charging }} {{ sd.appearance.dark }}');
          return r.slots.length + '|' + r.deps.size + '|' + r.deps.has(sd.battery) + '|' + r.deps.has(sd.appearance);
        })()
        """)
        try expectEqual(probe, "3|2|true|true")
    }

    test("template compile: 'sd.battery.percent' deps are exactly the battery signal") {
        // __sdCompilePlaceholder regex-matches each sd.<path> against the
        // known signal table and records the signal object to subscribe.
        let probe = JSHarness.evalString("""
        (function() {
          const deps = __sdCompilePlaceholder('sd.battery.percent').deps;
          return deps.length + '|' + (deps[0] === sd.battery);
        })()
        """)
        try expectEqual(probe, "1|true")
    }

    test("template compile: a path that only shares a prefix with a channel is not a dep") {
        // The word boundary after each channel path keeps
        // sd.windows.focusedChanged from also subscribing sd.windows.focused.
        let probe = JSHarness.evalString("""
        (function() {
          const deps = __sdCompilePlaceholder('sd.windows.focusedChanged.value').deps;
          return deps.length + '|' + (deps[0] === sd.windows.focusedChanged);
        })()
        """)
        try expectEqual(probe, "1|true")
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

    test("template eval: item/index bind in scope; null and throwing results render empty") {
        let probe = JSHarness.evalString("""
        (function() {
          return [
            __sdEvalWithScope(__sdCompilePlaceholder('item.name + index'), { name: 'kite' }, 2),
            __sdEvalWithScope(__sdCompilePlaceholder('null'), undefined, undefined),
            __sdEvalWithScope(__sdCompilePlaceholder('item.missing.deep'), {}, 0),
            __sdEvalWithScope(__sdCompilePlaceholder('0'), undefined, undefined)
          ].join('|');
        })()
        """)
        try expectEqual(probe, "kite2|||0")
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
        // template silently evaluates to undefined. signal() returns a Proxy
        // that falls through to .value for keys the wrapper doesn't own.
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
          // The payload carries a `warp` key of its own; the wrapper's
          // Object.assign'd sd.mouse.warp method must still win.
          window.__sd_push('mouse', { x: 100, y: 200, warp: 'payload' });
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
        // `sd.windows.all.map(...)` and `sd.windows.all.length` must work
        // before the first push without a `|| []` guard in every stack.
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
