# The reactive model

A stack receives daemon-side state through three distinct mechanisms. Pick the one that matches the shape of the data:

- **Channels** — named streams the daemon *pushes* when state changes (battery, windows, mouse…).
- **Bangs** — fire-and-forget named events any stack or the daemon can emit (window lifecycle, cross-stack signals).
- **Requests** — one-shot "do this and return a value" calls (`await sd.fs.read(...)`).

## Channels (push signals)

Each `sd.<path>` is a **signal**: a small object with `.value`, `.subscribe(fn)`, `.peek()`, and `.first(predicate)`.

- **Subscribe** to react on every change. `fn` is called once immediately with the current value, then on every subsequent push.
- **`.peek()`** reads the latest value synchronously, without subscribing.
- **`.first(pred)`** awaits the first value matching a predicate (default: any non-null).
- The signal is also a **Proxy**: `sd.battery.percent` reads `percent` off the current payload directly, so `{{ sd.battery.percent }}` and field access work without `.value` ceremony.

```js
sd.mouse.subscribe(({ x, y }) => console.log(x, y));   // fires on every move
const dark = sd.appearance.peek()?.dark;               // one-shot read
const m = await sd.mouse.first();                       // await first value
```

A signal only fires subscribers when the value actually changes (`Object.is` guard), and the daemon dedupes against its last-sent state before pushing, so identical payloads never cross the bridge.

### Throttling poll-driven channels

`subscribe(fn, { interval: 5 })` asks the daemon to slow its push cadence for this stack to once per 5 seconds. Only **poll-driven** channels honor it (e.g. `sd.sensors`, `sd.host.load`, `sd.display.all`); event-driven channels (`sd.mouse`, `sd.app.frontmost`, `sd.audio`) ignore the interval but still deliver every change.

```js
sd.sensors.subscribe(s => render(s), { interval: 10 });  // sample every 10s
```

## Replay on load (snapshot vs delta)

When a stack finishes loading, the daemon immediately re-pushes the cached value of every **replayable** channel the stack has permission for. That's why a freshly-loaded stack starts with correct state instead of a blank screen — you don't have to wait for the next change.

This splits channels in two:

- **Replayable (snapshot) channels** cache their latest payload. They describe *state* — e.g. `battery`, `mouse`, `windows.all`, `appearance` — so they replay on load.
- **Delta channels** are pure *events*. Their payload only makes sense as a transition — e.g. `apps.changed` and the window-lifecycle bangs (`windows.created`, `…destroyed`) — so there's nothing to replay; subscribing only catches future deltas.

The exhaustive partition lives in `Sources/Channels.swift` (the `replayable` flag) and is tagged per channel in the [`sd.*` API reference](../reference/api.md) — that's the single source of truth, not a list maintained here.

> Some channels have **no template surface** (`menubar` items, the window-lifecycle bangs) — there's no `{{ sd.… }}` for them. Reach those via explicit JS subscription / bang handlers.

## Requests (one-shot)

For reads and actions that return a value, the API uses request/response — the call returns a Promise:

```js
const text = await sd.fs.read("~/notes.txt");
await sd.media.command("next");
const rows = await db.query("select * from t");
```

This is the web-native replacement for Hammerspoon's synchronous Lua returns. Rule of thumb: **channels for state that streams; requests for "do this once and tell me the result."**

## Bangs (events)

A **bang** is a named fire-and-forget event (the name comes from LiteStep). Any stack or the daemon can fire a bang; every stack that handles that name receives it. Two ways to handle one:

**Modern — `sd.bang.declare(name).on(handler)` (auto-registers, no manifest entry):**
```js
const reload = sd.bang.declare("ReloadAll");
reload.on(detail => { /* react */ });   // auto-registered
reload.emit({ reason: "user" });         // producer & consumer share the handle
```

**Legacy — `window.onBang_<name>` + manifest `handles`:** list the bang name in the manifest's `handles` array and assign a global `window.onBang_<slug>` handler. Both routes dispatch through the same slot, so they interoperate; adopt the modern form for new stacks.

`sd.bang(name, detail)` is the bare emit if you don't need a declared handle.

### Window-lifecycle bangs

The daemon fires these as windows change. Subscribe via `sd.windows.<name>.subscribe(...)` (requires the `windows` permission), or via `handles` + `onBang_*`:

| Bang | Payload |
|---|---|
| `sd.window.created` | `{ id, pid, app, title, frame }` |
| `sd.window.destroyed` | `{ id }` |
| `sd.window.titleChanged` | `{ id, app, title, oldTitle, frame, pid }` |
| `sd.window.moved` | `{ id, frame }` (high rate during drag) |
| `sd.window.resized` | `{ id, frame }` (high rate during resize) |
| `sd.window.minimized` / `.deminimized` | `{ id }` |
| `sd.window.reordered` | `{ id }` (z-order change) |
| `sd.window.focusedByMouse` | `{ }` |

## See also

- [Template engine](../reference/template-engine.md) — bind channels into the DOM with `{{ }}`
- [`sd.*` API](../reference/api.md) — every channel and method
- [Permissions](permissions.md) — what each channel requires
