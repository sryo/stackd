import Foundation

/// JSC tests for the sd-on:click runtime pieces that don't need a real DOM:
/// attribute compilation (__sdSetupOnClickElement against a fake element),
/// handler registration, and click dispatch with sd-each item/index scope
/// (__sdDispatchOnClick walking fake parent chains). The rect tracker and
/// the daemon hover flip are DOM/eventtap-coupled — covered by the
/// click-counter example against the live daemon.
func registerSdOnClickTests() {
    let ctx = JSHarness.context

    // A minimal element double: enough surface for __sdSetupOnClickElement
    // and __sdDispatchOnClick (get/set/has/removeAttribute + parentElement).
    let fakeElDef = """
    function __makeFakeEl(attrs, parent) {
      return {
        __attrs: Object.assign({}, attrs || {}),
        parentElement: parent || null,
        getAttribute(n)    { return (n in this.__attrs) ? this.__attrs[n] : null; },
        setAttribute(n, v) { this.__attrs[n] = String(v); },
        hasAttribute(n)    { return (n in this.__attrs); },
        removeAttribute(n) { delete this.__attrs[n]; }
      };
    }
    """
    _ = ctx.evaluateScript(fakeElDef)

    test("sd-on:click: setup moves the attribute to data- markers and registers a handler") {
        let r = ctx.evaluateScript("""
        (function () {
          const el = __makeFakeEl({ "sd-on:click": "globalThis.__clicked = true" });
          __sdSetupOnClickElement(el);
          const id = el.getAttribute("data-sd-on-click");
          return [
            el.hasAttribute("sd-on:click"),
            id !== null,
            el.hasAttribute("data-sd-interactive"),
            __sdOnHandlers.has(id)
          ].join(",");
        })()
        """)
        try expectEqual(r?.toString(), "false,true,true,true")
    }

    test("sd-on:click: dispatch evaluates the expression") {
        let r = ctx.evaluateScript("""
        (function () {
          globalThis.__hits = 0;
          const el = __makeFakeEl({ "sd-on:click": "globalThis.__hits++" });
          __sdSetupOnClickElement(el);
          __sdDispatchOnClick(el);
          __sdDispatchOnClick(el);
          return globalThis.__hits;
        })()
        """)
        try expectEqual(r?.toInt32(), 2)
    }

    test("sd-on:click: dispatch bubbles from a child to the marked ancestor") {
        let r = ctx.evaluateScript("""
        (function () {
          globalThis.__bubbled = 0;
          const btn = __makeFakeEl({ "sd-on:click": "globalThis.__bubbled++" });
          __sdSetupOnClickElement(btn);
          const span = __makeFakeEl({}, btn);  // <span> inside the button
          __sdDispatchOnClick(span);
          return globalThis.__bubbled;
        })()
        """)
        try expectEqual(r?.toInt32(), 1)
    }

    test("sd-on:click: item/index resolve from the nearest __sdScope ancestor") {
        let r = ctx.evaluateScript("""
        (function () {
          globalThis.__got = null;
          const cloneRoot = __makeFakeEl({});
          cloneRoot.__sdScope = { item: { name: "kite" }, index: 3 };
          const btn = __makeFakeEl({ "sd-on:click": "globalThis.__got = item.name + ':' + index" }, cloneRoot);
          __sdSetupOnClickElement(btn);
          __sdDispatchOnClick(btn);
          return globalThis.__got;
        })()
        """)
        try expectEqual(r?.toString(), "kite:3")
    }

    test("sd-on:click: handler errors are contained (dispatch doesn't throw)") {
        let r = ctx.evaluateScript("""
        (function () {
          const el = __makeFakeEl({ "sd-on:click": "globalThis.__noSuchFn()" });
          __sdSetupOnClickElement(el);
          try { __sdDispatchOnClick(el); return "contained"; }
          catch (e) { return "leaked: " + e; }
        })()
        """)
        try expectEqual(r?.toString(), "contained")
    }

    test("sd-on:click: empty expression is ignored (no marker, no handler)") {
        let r = ctx.evaluateScript("""
        (function () {
          const before = __sdOnHandlers.size;
          const el = __makeFakeEl({ "sd-on:click": "  " });
          __sdSetupOnClickElement(el);
          return [el.hasAttribute("data-sd-on-click"), __sdOnHandlers.size === before].join(",");
        })()
        """)
        try expectEqual(r?.toString(), "false,true")
    }
}
