# Lifecycle & rules

A handful of invariants the daemon enforces. Working *with* them keeps stacks predictable; fighting them produces bugs.

## Where stacks live

Installed stacks live at **`~/stackd/stacks/<id>/`**. The repo's `examples/` folder is demo/test scaffolding only. If you maintain a stack in both places, change both.

## Reload

After editing a stack, run:

```sh
stackd reload
```

A reload re-runs the stack from a clean page. Everything tied to the page drops — channel subscriptions, bang routers, hotkey/eventtap handler maps, timers. Then on the stack's next `ready`, the daemon re-fires `replayState()`: every **replayable** channel the stack has permission for immediately re-pushes its current snapshot, so the stack paints correct state on load. (See [replay](reactive-model.md#replay-on-load-snapshot-vs-delta).)

Write stacks to be **reload-safe**: don't depend on state surviving a reload; rebuild from channels on load. The `sd.timer.*` helpers and `sd.bind`/`sd.tpl` auto-clean on page unload for exactly this reason.

## The daemon never becomes the active app

The one focus-related invariant: the stackd process never becomes the frontmost (active) application. It runs as an `.accessory` (no Dock icon), its panels are non-activating, and `NSApp.activate(...)` is never called.

This is **not** "stacks can't be interactive or focused." Plenty of stacks capture clicks (`clickThrough: false`) and plenty take keyboard focus on demand (`invocable: true`) — a panel can receive clicks and keys without your frontmost app changing. The only thing that doesn't exist is "raise my panel and make stackd the active app"; don't design around that semantic.

## Stacks don't poll

**Polling lives in the daemon, never in a stack.** A `setInterval` that reads OS state is a missing channel. The daemon already owns the diff math and takes a single shared sample per tick across all stacks; your job is to subscribe.

```js
// WRONG — stack polling the OS
setInterval(() => refreshThroughput(), 1000);

// RIGHT — subscribe to the daemon channel
sd.net.throughput.subscribe(({ rxBps, txBps }) => render(rxBps, txBps));
```

If the data you need has no channel, that's a gap in the daemon to fill — not a reason to poll from the stack. (For purely UI-side timing — animations, debouncing your own logic — `sd.timer.*` is fine; the rule is about polling *macOS state*.)

## Namespaces are lowercase-smashed

Multiword `sd.*` namespaces concatenate without camelCase: **`httpserver`**, **`urlhandler`**, **`touchdevice`** — not `httpServer`. (`displayLink` is the one grandfathered exception.) This is frozen; permission names match the namespace.

## The daemon owns its own lifecycle

Rebuild/launch/kill/reload of the daemon itself is a daemon concern. From an author's seat you only ever `stackd reload` to pick up stack edits. If native window operations suddenly fail after a daemon rebuild, it's usually revoked Accessibility trust — see [Permissions → TCC](permissions.md#macos-consent-prompts-tcc-to-expect).

## See also

- [The reactive model](reactive-model.md) — subscribe instead of poll
- [Chrome & material](chrome-and-material.md) — declarative chrome, never-frontmost
- [Manifest reference](../reference/manifest.md) — `invocable`, `headless`, `level`
