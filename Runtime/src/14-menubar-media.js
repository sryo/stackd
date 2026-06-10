sd.menubar = {
    // Reference-counted system menu-bar visibility.
    // Multiple stacks can suppress; the bar reappears only once every
    // suppressor has called restore().
    suppress() { return request({ type: "menubar.suppress" }); },
    restore()  { return request({ type: "menubar.restore"  }); },

    // Read-only AX walk of every visible menubar status item — third-party
    // app icons + Apple's Spotlight + clock. Returns an array of
    //   { owner, title, x, width, hidden }
    // sorted left-to-right by x. `owner` is the bundle identifier (or
    // localized name) of the app that owns the item. `hidden` flags items
    // pushed past the system's chevron / off-screen (notch overflow on
    // MacBook Pro 14"/16", or too many items for the bar width).
    //
    // Requires the "menubar" permission (same gate as suppress/restore +
    // observe). macOS 14+ Control Center group (Wi-Fi / Bluetooth / Focus
    // / etc.) lives in a separate AXSystemUIServer process and is NOT
    // included — documented limitation, not a bug.
    items() { return request({ type: "menubar.items" }); },

    // Subscribable signal that fires whenever the menubar item set changes
    // (item added / removed / repositioned). Backed by a 2s poll-and-diff
    // — AX has no reliable push for status-item add/remove. Payload is the
    // same shape as items(). Tunable cadence per-stack:
    //   sd.menubar.observe.subscribe(items => render(items), { interval: 5 });
    // Same "menubar" permission gate as items() / suppress / restore.
    observe: channel("menubarItems"),
    // Transition deltas paralleling sd.windows.changed / sd.apps.changed:
    // { added: [...], removed: [...], changed: [...] }. Identity is
    // owner+title (menubar items have no stable id); "changed" tracks
    // x / width / hidden transitions. Suppresses the first-tick
    // "everything added" — for that subscribe to .observe.
    changed: channel("menubarChanged"),

    // Add an NSStatusItem to the system menu bar. Requires "menubar.item"
    // permission (distinct from "menubar", which gates suppress/restore).
    //
    // spec: {
    //   icon?:    { sfSymbol?, pngBase64?, template? }   // template defaults true
    //   title?:   string
    //   menu?:    [{ id, title, separator?, submenu?, enabled?, checked? }]
    //   tooltip?: string
    //   onClick?: () => void                             // ignored if `menu` set
    //   onMenuPick?: (id: string) => void                // fires with menu-item.id
    // }
    //
    // Returns a Promise<MenubarItem | null>. The handle's lifetime is bound
    // to the stack — unload removes the item automatically.
    async addItem(spec) {
      const { onClick, onMenuPick, icon, title, menu, tooltip } = spec || {};
      const id = await registerHandler(
        menubarHandlers,
        { type: "menubar.addItem", icon, title, menu, tooltip },
        { onClick, onMenuPick }
      );
      if (id == null) return null;
      return {
        id,
        setTitle(s)       { return request({ type: "menubar.item.setTitle",   id, title: s }); },
        setIcon(iconSpec) { return request({ type: "menubar.item.setIcon",    id, icon: iconSpec }); },
        setMenu(items)    { return request({ type: "menubar.item.setMenu",    id, items }); },
        setTooltip(s)     { return request({ type: "menubar.item.setTooltip", id, tooltip: s }); },
        remove() {
          return unregisterHandler(menubarHandlers, id, { type: "menubar.item.remove", id });
        },
        // Re-assign callbacks after construction (e.g. once a dynamic menu
        // is wired up). Map stays internal.
        set onClick(fn)    { const e = menubarHandlers.get(id) || {}; e.onClick    = fn; menubarHandlers.set(id, e); },
        set onMenuPick(fn) { const e = menubarHandlers.get(id) || {}; e.onMenuPick = fn; menubarHandlers.set(id, e); }
      };
    }
  };
sd.media = {
    // Covers Spotify / Apple Music / Podcasts / browser audio.
    // command(name) — "play" | "pause" | "toggle" | "stop" | "next" |
    //                 "previous" | "skipForward" | "skipBackward"
    nowPlaying: channel("media"),
    command(name) { return request({ type: "media.command", name }); }
  };
sd.settings = {
    // Per-stack k/v persistence, scoped to this stack's id.
    // Stored values must be JSON-compatible.
    get(key)        { return request({ type: "settings.get",    key }); },
    set(key, value) { return request({ type: "settings.set",    key, value }); },
    delete(key)     { return request({ type: "settings.delete", key }); },
    all()           { return request({ type: "settings.all" }); }
  };
