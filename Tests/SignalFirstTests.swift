import Foundation
import JavaScriptCore

/// Tests for the `.first(predicate?)` method on every sd.* signal.
/// Default predicate is "non-null." Resolves synchronously (via Promise
/// microtask) when peek() already matches, otherwise subscribes and
/// resolves on the first matching push.
///
/// Pattern note: JSC drains pending microtasks at every `evaluateScript`
/// boundary, so the test stores resolution into a `window.__*` global and
/// reads it back in a separate evaluateScript call.
func registerSignalFirstTests() {
    test("signal.first(): resolves immediately when current value matches default predicate") {
        _ = JSHarness.context.evaluateScript("""
            window.__sd_push('battery', { percent: 50 });
            window.__sft_sync = 'pending';
            sd.battery.first().then(v => { window.__sft_sync = String(v.percent); });
        """)
        let out = JSHarness.context.evaluateScript("window.__sft_sync")?.toString()
        try expectEqual(out, "50")
    }

    test("signal.first(): resolves on first matching push when value starts null") {
        _ = JSHarness.context.evaluateScript("""
            window.__sd_push('battery', null);
            window.__sft_push = 'pending';
            sd.battery.first().then(v => { window.__sft_push = String(v.percent); });
            window.__sd_push('battery', { percent: 80 });
        """)
        let out = JSHarness.context.evaluateScript("window.__sft_push")?.toString()
        try expectEqual(out, "80")
    }

    test("signal.first(predicate): waits past pushes that don't satisfy the predicate") {
        _ = JSHarness.context.evaluateScript("""
            window.__sd_push('battery', { percent: 10 });
            window.__sft_pred = 'pending';
            sd.battery.first(v => v && v.percent >= 50).then(v => { window.__sft_pred = String(v.percent); });
            window.__sd_push('battery', { percent: 20 });
            window.__sd_push('battery', { percent: 60 });
            window.__sd_push('battery', { percent: 90 });
        """)
        let out = JSHarness.context.evaluateScript("window.__sft_pred")?.toString()
        try expectEqual(out, "60")
    }

    test("signal.first(): unsubscribes after resolving (subsequent pushes don't re-fire .then)") {
        _ = JSHarness.context.evaluateScript("""
            window.__sd_push('battery', null);
            window.__sft_count = 0;
            sd.battery.first().then(v => { window.__sft_count += 1; });
            window.__sd_push('battery', { percent: 30 });
            window.__sd_push('battery', { percent: 40 });
            window.__sd_push('battery', { percent: 50 });
        """)
        let out = JSHarness.context.evaluateScript("window.__sft_count")?.toString()
        try expectEqual(out, "1")
    }

    test("signal.first(): works through the Proxy wrapper (own key, not payload fall-through)") {
        // `first` is on the base signal object; the Proxy returns it via
        // Reflect.get. Regression guard if someone moves the method off `base`.
        let out = JSHarness.context.evaluateScript("typeof sd.battery.first")?.toString()
        try expectEqual(out, "function")
    }
}
