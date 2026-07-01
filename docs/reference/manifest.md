# Manifest reference (`stack.json`)

Every stack is a folder under `~/stackd/stacks/<id>/` (or `examples/<id>/` in the repo) containing `stack.json`, `index.html`, and assets. `stack.json` is decoded into `StackManifest` (`Sources/StackHost.swift`). Keys not listed below are ignored. A repo-wide `defaults.json` (see end) is merged *under* each manifest, so any field can be set as a global default.

## Required vs optional

Only **`id`** and **`name`** are required. Everything else is optional with the defaults below.

> `permissions` is technically non-optional in the decoder, but it's almost always supplied (by you or by `defaults.json`) and channel permissions are inferred from your source anyway. **Always write `"permissions": []` at minimum** so a hand-written manifest decodes.

## Field table

| Key | Type | Default | Allowed values | Effect |
|---|---|---|---|---|
| `id` | string | — (required) | any | Folder-matching identity; URL host (`sd://<id>/index.html`) and permission/registry key. |
| `name` | string | — (required) | any | Human-readable label (logs, CLI listings). |
| `region` | string | none | `"menubar"`, `"fullscreen"` | Overrides anchor/size. `menubar` = full-width bar over the system menu bar; `fullscreen` = entire `screen.frame`. |
| `anchor` | object `{edge, inset}` | `top-right`, inset `[16,16]` | see edges below | Positions the panel in the screen's visible frame. Ignored when `region` is set. |
| `anchor.edge` | string | `"top-right"` | `top-right`, `top-left`, `bottom-right`, `bottom-left`, `top-center`, `bottom-center`, `top`, `bottom`, `left`, `right` (unknown → centered) | Which edge/corner to pin to. |
| `anchor.inset` | int[2] | `[16,16]` | `[insetY, insetX]` in points | Offset from the anchored edge. **Index 0 is Y, index 1 is X.** |
| `size` | object `{w?, h}` | `w` = full visible width, `h` = `1` | `h` required if `size` present | Panel dimensions in points. |
| `size.w` | int | full visible-frame width | any | Width. Ignored for full-bleed edges (`top`/`bottom` stretch across); the thickness for `left`/`right`. |
| `size.h` | int | `1` | any | Height. For `region:"menubar"`: `0`/unset → match this display's menubar height; `>0` → `max(h, menubarHeight)`. |
| `display` | string | `"primary"` | `"primary"`, `"all"`, `"<index>"` (e.g. `"1"`) | Which screen(s). `"all"` spawns one instance per display, keyed `<id>@<N>`. |
| `clickThrough` | bool | `true` | `true`/`false` | `true` → mouse events pass through (`ignoresMouseEvents`). Forced `true` for headless, `false` for invocable. |
| `headless` | bool | `false` | `true`/`false` | Background-only stack: invisible 1×1, click-through; ignores anchor/size/material/cornerRadius/shape/padding. |
| `invocable` | bool | `false` | `true`/`false` | Starts hidden, can take keyboard focus via `sd.window.invoke()` (`canBecomeKey=true`). |
| `level` | string | `"overlay"` (`"bar"` if `region:"menubar"`) | `"bar"`(900), `"overlay"`(950), `"tooltip"`(1000), `"cursor"`(1050), `"high"`(999), or numeric string | Window stacking level. |
| `material` | string | `"none"` | see [Chrome & material](../concepts/chrome-and-material.md) | Backing material (glass / vibrancy / tinted). Unknown → `none` + warning. |
| `cornerRadius` | number | none | any ≥ 0 (negatives clamped) | Rounds the panel. Applies to any material. Ignored when `shape:"capsule"`. |
| `shape` | string | `"rect"` | `"rect"`, `"capsule"` | `capsule` derives radius = `min(w,h)/2`, ignoring `cornerRadius`. |
| `padding` | number | `0` (auto `cornerRadius/2` for glass w/ radius) | any ≥ 0 | Inset between material edge and WebView. Explicit value (even `0`) wins. Full-bleed → set `0`. |
| `reset` | bool | `true` | `true`/`false` | Inject a minimal CSS reset (`margin:0;padding:0;background:transparent`). |
| `permissions` | string[] | (always write it) | any of the permission list below | Native capabilities/channels. Channel + RPC perms auto-inferred from source; composites must be explicit. |
| `handles` | string[] | none | any bang names | Legacy bangs handled via `window.onBang_<name>`. Modern `sd.bang.declare().on()` needs no entry. |
| `hotkeys` | object[] | none | see below | Global Carbon hotkeys for the stack's lifetime. |
| `eventtap` | object[] | none | see below | CGEventTap subscriptions. |

### Edge taxonomy

- **Corners** (`top-right`, etc.): manifest `w`×`h` used as-is, offset by inset.
- **Horizontal-center** (`top-center`, `bottom-center`): `w` used, centered on midX; `insetY` from the edge.
- **Full-bleed edges** (`top`/`bottom`): stretch across visible width, `h` = thickness. (`left`/`right`): stretch full height, `w` = thickness.
- **Unknown**: centered in the visible frame.

## `material` values

See [Chrome & material](../concepts/chrome-and-material.md#material) for the full table: `none`, `glass`, `glass.clear`, `glass.tinted(#RRGGBB)`, `vibrancy.<key>`. Don't use CSS `backdrop-filter`; glass panels have no shadow by design.

## `permissions` — full list

`Sources/Permissions.swift`. **Channel-vending** (auto-inferable): `battery`, `mouse`, `appearance`, `caffeinate`, `sensors`, `location`, `usb`, `camera`, `touchdevice`, `displayLink`, `app`, `windows`, `input`, `net`, `audio`, `display`, `media`, `pasteboard`, `apps`, `spaces`, `host`, `calendar`, `menubar`, `privacy`.

**RPC namespaces** (also inferable): `fs`, `proc`, `applescript`, `notify`, `settings`, `defaults`, `broadcasts`, `ax`, `spotlight`, `speech`, `vision`, `nlp`, `bonjour`, `httpserver`, `sqlite`, `update`, `cursor`, `overlay`, `shortcuts`, `sound`, `icons`, `thumbnails`, `events`, `menu`, `bluetooth`, `disks`, `hotkey`, `urlhandler`.

**Composite** (NEVER inferred — declare explicitly): `menubar.item`. See [Permissions](../concepts/permissions.md).

## `hotkeys` entry

```json
{ "key": "ctrl+alt+cmd+m", "callback": "toggle", "mode": "default", "apps": ["com.apple.Safari"], "excludeApps": ["com.apple.Terminal"] }
```

| Field | Type | Default | Effect |
|---|---|---|---|
| `key` | string (required) | — | Chord; grammar below. |
| `callback` | string (required) | — | Invokes `window.onHotkey_<callback>` (or a handler registered via `sd.hotkey.on(name, fn)`). |
| `mode` | string? | `nil` (always fires) | skhd-style modal gate; fires only when the current hotkey mode matches. |
| `apps` | string[]? | `nil` (ungated) | Fires only when frontmost bundleID is listed; `["*"]` = any. |
| `excludeApps` | string[]? | `nil` | Suppressed when frontmost bundleID matches. |

### `key` grammar

Lowercased, split on `+`. Modifiers (any order): `cmd`/`command`/`meta` (⌘), `ctrl`/`control` (⌃), `alt`/`option`/`opt` (⌥), `shift` (⇧). `fn` is **accepted but skipped** for hotkeys (no Carbon support) — it works only for synthesized `sd.events.key()` combos. Exactly one non-modifier key token: `a`–`z`, `0`–`9`, `space`, `return`/`enter`, `escape`/`esc`, `tab`, `delete`/`backspace`, arrows (`left`/`right`/`up`/`down`), and punctuation `minus`(`-`), `equal`(`=`), `comma`(`,`), `period`(`.`), `slash`(`/`), `semicolon`(`;`), `quote`(`'`), `leftbracket`(`[`), `rightbracket`(`]`), `backslash`(`\`), `grave`(`` ` ``). Unknown key → binding skipped with a logged warning. US-keyboard keycodes.

## `eventtap` entry

```json
{ "event": "leftMouseDown", "callback": "click", "consume": true, "requireRects": true,
  "if": { "keyCode": 53, "keyCodes": [123,124], "flagsMask": 1048576, "flagsAny": 131072 } }
```

| Field | Type | Default | Effect |
|---|---|---|---|
| `event` | string (required) | — | Event type (list below). Unknown → skipped + warning. |
| `callback` | string (required) | — | Invokes `window.onTap_<callback>` (or a handler via `sd.events.on(name, fn)`) with the event payload. |
| `consume` | bool? | `false` | `true` → consuming tap: the `if` predicate runs synchronously in the tap and matching events are swallowed. Empty/missing `if` = consume every event of that type. |
| `requireRects` | bool? | `false` | Tap stays inert until JS calls `sd.events.setTapRects(callback, [...])` — closes the boot race for cursor-gated taps. |
| `emitLeave` | bool? | `false` | Observer taps only; **requires `requireRects:true`**. Adds `phase: "enter"\|"move"\|"leave"` so hot-corner stacks drop polling. |
| `if` | object? | none | Predicate (consume path only): `keyCode` (int), `keyCodes` (int[]), `flagsMask` (uint), `flagsAny` (uint). |

**Supported `event` names:** `keyDown`, `keyUp`, `flagsChanged`, `leftMouseDown`, `leftMouseUp`, `rightMouseDown`, `rightMouseUp`, `otherMouseDown`, `otherMouseUp`, `leftMouseDragged`, `rightMouseDragged`, `mouseMoved`, `scrollWheel`, `gesture`.

**Callback payload:** `{ type, keyCode, flags, x, y }`, plus `deltaX`/`deltaY` for `mouseMoved` and dragged variants, gesture fields for `gesture`, and `phase` only when `emitLeave` is active.

## `defaults.json` (repo-wide, not per-stack)

A `defaults.json` next to the `stacks/` directory supplies manifest defaults merged *under* every stack's `stack.json` (per-stack keys win). It's a sibling file, not a manifest field. (Pattern from SketchyBar's `--default`.)

## Fully-worked example

```json
{
  "id": "edge-hud",
  "name": "Edge HUD",
  "display": "all",
  "anchor": { "edge": "bottom-center", "inset": [24, 0] },
  "size": { "w": 320, "h": 64 },
  "level": "tooltip",
  "material": "glass.tinted(#1E1E2A)",
  "cornerRadius": 28,
  "padding": 12,
  "clickThrough": true,
  "permissions": ["battery", "audio", "events", "applescript"],
  "handles": ["hud.flash"],
  "hotkeys": [
    { "key": "ctrl+alt+cmd+h", "callback": "toggle", "apps": ["*"], "excludeApps": ["com.apple.Terminal"] }
  ],
  "eventtap": [
    { "event": "leftMouseDown", "callback": "click", "consume": true, "requireRects": true },
    { "event": "mouseMoved", "callback": "hover", "requireRects": true, "emitLeave": true },
    { "event": "keyDown", "callback": "key", "consume": true, "if": { "keyCodes": [53], "flagsMask": 1048576 } }
  ]
}
```

Minimal valid manifest:
```json
{ "id": "dot", "name": "Dot", "permissions": [] }
```

## Gotchas

- `anchor.inset` is `[Y, X]`, not `[X, Y]`.
- `fn` is dropped from **hotkey** chords (works for `sd.events.key()` synthesis).
- `headless:true` overrides material/cornerRadius/shape/padding/anchor/size/clickThrough.
- `emitLeave` requires `requireRects:true` or it's inert.
- `if` predicates apply only to **consuming** taps; observer taps ignore them.
- Material/cornerRadius/padding are daemon-owned — don't replicate via CSS; full-bleed content needs explicit `"padding": 0`.

## See also

- [Chrome & material](../concepts/chrome-and-material.md) · [Permissions](../concepts/permissions.md) · [Template engine](template-engine.md) · [`sd.*` API](api.md)
