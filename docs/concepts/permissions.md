# Permissions

Every `sd.*` primitive is gated by a permission string in a stack's manifest `permissions` array. The canonical registry is `Permissions.all` in `Sources/Permissions.swift`. In practice you rarely write the list by hand.

## Inference

The daemon **infers** permissions by scanning your stack's source: any `sd.<name>.` reference in JS, and any `{{ sd.<name>… }}` placeholder in HTML, auto-adds the matching permission.

```js
sd.battery.subscribe(...)   // → "battery" inferred automatically
```
```html
<div>{{ sd.audio.output.volume }}</div>   <!-- → "audio" inferred -->
```

So the battery HUD in [Getting started](../getting-started.md) works with `"permissions": []`. Inference matches on the **top-level namespace** with word boundaries, so `sd.batteryFoo` does not match `battery`.

> Best practice: even though RPC namespaces (`fs`, `proc`, `notify`…) are also inferable, listing them explicitly in `permissions` keeps a stack's capabilities visible to anyone reviewing it.

## Inferable vs composite

- **Inferable permissions** (`Permissions.inferable`, which is `all` minus the composites) auto-add from source mentions — this is almost everything.
- **Composite permissions** carry stricter side-effects than their base namespace and are **excluded from inference** — you must declare them explicitly.

The example is **`menubar.item`**. The base `menubar` permission covers the *read* path (observing menu-bar items); `menubar.item` is a *write* surface — it mutates the system menu bar — so it stays out of inference and requires an explicit opt-in that keeps the side-effect obvious at review time:

```json
{ "permissions": ["menubar.item"] }
```

## Graceful no-op / feature-detect

Channels with no data yet **push nothing** rather than erroring — `sd.host.load`, `sd.touchdevice`, `sd.displayLink`, `sd.net.path`, and `sd.location` all start empty and only push once a real sample exists. So a signal still at its initial `null`/`[]` means "no data yet," not "broken."

Design for it:

```js
// await the first real value instead of assuming a snapshot exists at load
const fix = await sd.location.first();

// or guard in a template
{{ sd.location ? sd.location.lat.toFixed(3) : 'waiting for fix…' }}
```

## macOS consent prompts (TCC) to expect

stackd vendors real system capabilities, so some namespaces trigger Apple's privacy prompts the first time the user hits them. Expect these and degrade gracefully until the grant lands:

| Capability | Triggered by |
|---|---|
| **Accessibility (AX)** | Reading/setting windows (`sd.windows.*` properties, AX walks), the menu-bar AX observer. Required for most window work. |
| **Screen Recording** | Window titles and on-screen content enumeration; window/display snapshots. |
| **Location** | `sd.location` — `null` until authorized and the first fix arrives. |
| **Camera / Microphone** | Opening a capture device (`sd.camera.frame`/`.stream`, `sd.speech.listen`). *Reading* `sd.privacy` / `sd.audio.input` to report what's recording does **not** prompt. |
| **Calendar / Reminders** | `sd.calendar.events()` / `.reminders()` (separate grants). |
| **Bluetooth** | `sd.bluetooth.paired()`. |

> Daemon-side gotcha worth knowing: on an unsigned rebuild, macOS silently revokes Accessibility trust — if window operations stop working after a rebuild, re-grant AX in System Settings → Privacy & Security.

## See also

- [The reactive model](reactive-model.md) — what each channel pushes
- [Manifest reference](../reference/manifest.md#permissions) — the full permission list
- [`sd.*` API](../reference/api.md) — the permission for every namespace
