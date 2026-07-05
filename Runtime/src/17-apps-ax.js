sd.apps = {
    // running: signal<[{pid, bundleId, name, active, hidden, launchedAt?}]>
    // — fires on launch/quit/hide/unhide/activate.
    running: channel("apps", []),
    // Transition deltas: { added: [...], removed: [...], changed: [...] }.
    // Fires only when something actually changed (not the initial full list
    // — for that, subscribe to .running). Consumers that only care about
    // launches/quits don't have to diff the full list themselves.
    changed: channel("appsChanged"),
    launch(bundleId)          { return request({ type: "apps.launch", bundleId }); },
    focus(bundleId)           { return request({ type: "apps.focus",  bundleId }); },
    kill(bundleId, force)     { return request({ type: "apps.kill",   bundleId, force: !!force }); },
    // hide / unhide accept either a bundleId (string) or a pid (number).
    // The bundleId form goes through the bundle-id NSWorkspace lookup;
    // the pid form goes through NSRunningApplication(processIdentifier:).
    // unhide is pid-only — NSRunningApplication.unhide() needs a specific
    // process instance, and "unhide every running copy of a bundle" isn't
    // a coherent verb.
    hide(arg) {
      if (typeof arg === "number") return request({ type: "apps.hideByPid", pid: arg });
      return request({ type: "apps.hide", bundleId: arg });
    },
    unhide(pid)               { return request({ type: "apps.unhideByPid", pid }); },
    // Curated AX readers on a pid. Mirrors hs.application's menu /
    // findMenuItem / selectMenuItem / visibleWindows surface.
    //   const tree = await sd.apps.menu(pid);
    //   // → { title, role, children: [
    //   //     { title: "File", role: "AXMenuBarItem",
    //   //       children: [{ title: "New", role: "AXMenuItem",
    //   //                    enabled: true, shortcut: "⌘N" }, ...] }, ...] }
    //   await sd.apps.findMenuItem(pid, ["File", "Save As…"]);
    //   // → { title, role, enabled, marked? } | null
    //   await sd.apps.selectMenuItem(pid, ["File", "Save"]);
    //   // → boolean (true = AXPressAction succeeded)
    //   await sd.apps.visibleWindows(pid);
    //   // → [{ id, app, pid, title, frame, onscreen }, ...]  // filtered sd.windows.all, minimized dropped
    menu(pid)                  { return request({ type: "apps.menu", pid }); },
    findMenuItem(pid, path)    { return request({ type: "apps.findMenuItem", pid, path }); },
    selectMenuItem(pid, path)  { return request({ type: "apps.selectMenuItem", pid, path }); },
    visibleWindows(pid)        { return request({ type: "apps.visibleWindows", pid }); },
    // Per-pid window-set readers. Each returns CGWindowID(s) — chain into
    // sd.windows.byId.* (frame, title, focus, raise, snapshot, …) from JS.
    //   await sd.apps.focusedWindow(pid)  // → number | null  (AX focused)
    //   await sd.apps.mainWindow(pid)     // → number | null  (AX main)
    //   await sd.apps.allWindows(pid)     // → number[]       (all AX windows, includes minimized)
    // Mirrors hs.application:focusedWindow / :mainWindow / :allWindows.
    focusedWindow(pid)         { return request({ type: "apps.focusedWindow", pid }); },
    mainWindow(pid)            { return request({ type: "apps.mainWindow", pid }); },
    allWindows(pid)            { return request({ type: "apps.allWindows", pid }); },
    // Per-pid app state. Cheap NSWorkspace / NSRunningApplication reads —
    // no AX gate.
    //   await sd.apps.isFrontmost(pid)  // → boolean
    //   await sd.apps.isHidden(pid)     // → boolean
    isFrontmost(pid)           { return request({ type: "apps.isFrontmost", pid }); },
    isHidden(pid)              { return request({ type: "apps.isHidden", pid }); }
  };
sd.icons = {
    // Returns a `data:image/png;base64,...` URL you can drop into <img src="">.
    // Default size 64pt. Cached by the browser.
    app(bundleId, opts) { return request({ type: "icons.app",  bundleId, size: (opts && opts.size) || 64 }); },
    file(path, opts)    { return request({ type: "icons.file", path,     size: (opts && opts.size) || 64 }); }
  };
sd.symbol = {
    // Render an SF Symbol to a template PNG data-URL for use as a CSS mask
    // (tint it with `background: currentColor`). Resolves to
    // { dataURL, width, height } (points, natural aspect), or null if the
    // symbol name doesn't resolve. opts: { size, weight, scale }.
    render(name, opts = {}) {
      return request({ type: "symbol", name,
                       size:   opts.size   || 15,
                       weight: opts.weight || "regular",
                       scale:  opts.scale  || "medium" });
    }
  };
sd.ax = {
    // Back-compat: focused UI element of the frontmost app as a dict
    // { app, pid, role, roleDescription?, value?, selectedText?,
    //   selectedRange?: {location, length}, caretBounds?: {x,y,w,h} }
    focused() { return request({ type: "ax.focused" }); },

    // Generic axuielement-style API. Element handles are opaque integers
    // owned by this stack's bridge. Every read that returns an AXUIElement
    // (or array of them) mints a *new* handle — release with .release(h)
    // or .releaseAll() to keep the store from growing without bound.
    //
    // Marshalling:
    //   AXValue<CGRect>  ↔ {x,y,w,h}    AXValue<CGPoint>  ↔ {x,y}
    //   AXValue<CGSize>  ↔ {w,h}        AXValue<CFRange>  ↔ {location,length}
    //   AXUIElement      → number       arrays/dicts recurse
    application(pid)                  { return request({ type: "ax.application", pid }); },
    system()                          { return request({ type: "ax.system" }); },
    systemElementAtPosition(x, y)     { return request({ type: "ax.systemElementAtPosition", x, y }); },
    focusedElement()                  { return request({ type: "ax.focusedElement" }); },
    // System-wide focused element — mirrors HS's
    // ax.systemWideElement():attributeValue("AXFocusedUIElement"). Use this
    // when the focused element may sit OUTSIDE the frontmost app (system
    // dialogs, popovers, menu bar). For ordinary text-input anchoring this
    // returns the same thing as focusedElement(); for cross-app focus cases
    // it's the HS-faithful choice.
    focusedElementSystemWide()        { return request({ type: "ax.focusedElementSystemWide" }); },
    attributeNames(handle)            { return request({ type: "ax.attributeNames", handle }); },
    attribute(handle, name)           { return request({ type: "ax.attribute", handle, name }); },
    attributes(handle)                { return request({ type: "ax.attributes", handle }); },
    parameterizedAttributeNames(handle) { return request({ type: "ax.parameterizedAttributeNames", handle }); },
    parameterizedAttribute(handle, name, param) {
      return request({ type: "ax.parameterizedAttribute", handle, name, param });
    },
    actionNames(handle)               { return request({ type: "ax.actionNames", handle }); },
    isAttributeSettable(handle, name) { return request({ type: "ax.isAttributeSettable", handle, name }); },
    setAttribute(handle, name, value) { return request({ type: "ax.setAttribute", handle, name, value }); },
    performAction(handle, action)     { return request({ type: "ax.performAction", handle, action }); },
    children(handle)                  { return request({ type: "ax.children", handle }); },
    parent(handle)                    { return request({ type: "ax.parent", handle }); },
    role(handle)                      { return request({ type: "ax.role", handle }); },
    release(handle)                   { return request({ type: "ax.release", handle }); },
    releaseAll()                      { return request({ type: "ax.releaseAll" }); }
    // observe(...) deferred — see README. Stacks that need AX notifications
    // can poll via sd.app.frontmost + a setTimeout for now.
  };
