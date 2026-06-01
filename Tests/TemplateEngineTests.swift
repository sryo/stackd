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
}
