import Foundation
import JavaScriptCore

/// Tests for `sd.hotkey.on(name, fn)`, `sd.events.on(name, fn)`, and the
/// underlying `sd.handlers.register(kind, name, fn)` shim. Verifies that
/// these install the same `window.on<Kind>_<name>` slot the daemon already
/// dispatches against, and that the returned disposer cleanly reverts the
/// slot to its prior state.
func registerHandlersRegisterTests() {
    test("hotkey.on: installs window.onHotkey_<name> as the daemon dispatches against") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__hr_called = 0;
          sd.hotkey.on("hrTest1", () => { window.__hr_called += 1; });
          window.onHotkey_hrTest1();
          return String(window.__hr_called);
        })()
        """)?.toString()
        try expectEqual(out, "1")
    }

    test("hotkey.on: disposer clears the slot (handler no longer fires)") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__hr_disp = 0;
          const stop = sd.hotkey.on("hrTest2", () => { window.__hr_disp += 1; });
          window.onHotkey_hrTest2();
          stop();
          // After dispose the slot reverted to its prior value (undefined here),
          // so direct invocation will throw — guard with typeof.
          if (typeof window.onHotkey_hrTest2 === "function") window.onHotkey_hrTest2();
          return String(window.__hr_disp);
        })()
        """)?.toString()
        try expectEqual(out, "1")
    }

    test("hotkey.on: later .on() replaces earlier handler at same slot") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__hr_replace = "";
          sd.hotkey.on("hrTest3", () => { window.__hr_replace = "first"; });
          sd.hotkey.on("hrTest3", () => { window.__hr_replace = "second"; });
          window.onHotkey_hrTest3();
          return window.__hr_replace;
        })()
        """)?.toString()
        try expectEqual(out, "second")
    }

    test("events.on: installs window.onTap_<name> (daemon's eventtap dispatch slot)") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__hr_tap = null;
          sd.events.on("hrTap1", (e) => { window.__hr_tap = e && e.kind; });
          window.onTap_hrTap1({ kind: "scroll" });
          return window.__hr_tap;
        })()
        """)?.toString()
        try expectEqual(out, "scroll")
    }

    test("events.on: disposer restores prior assignment (chaining preserves legacy)") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__hr_chain = 0;
          window.onTap_hrChain = () => { window.__hr_chain += 100; };
          const stop = sd.events.on("hrChain", () => { window.__hr_chain += 1; });
          window.onTap_hrChain();        // new handler fires → +1
          stop();
          window.onTap_hrChain();        // prior handler restored → +100
          return String(window.__hr_chain);
        })()
        """)?.toString()
        try expectEqual(out, "101")
    }

    test("handlers.register: generic entry-point matches sd.events.on / sd.hotkey.on") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__hr_generic = 0;
          sd.handlers.register("Hotkey", "hrGen1", () => { window.__hr_generic += 7; });
          window.onHotkey_hrGen1();
          sd.handlers.register("Tap", "hrGen2", () => { window.__hr_generic += 13; });
          window.onTap_hrGen2();
          return String(window.__hr_generic);
        })()
        """)?.toString()
        try expectEqual(out, "20")
    }

    test("legacy: bare window.onHotkey_<name> = fn assignment still works (no migration required)") {
        let out = JSHarness.context.evaluateScript("""
        (function() {
          window.__hr_legacy = 0;
          window.onHotkey_hrLegacy = () => { window.__hr_legacy += 1; };
          window.onHotkey_hrLegacy();
          return String(window.__hr_legacy);
        })()
        """)?.toString()
        try expectEqual(out, "1")
    }
}
