# Chrome & material

The daemon owns all window chrome — material, corner radius, padding, placement, click-through. You select it **declaratively in the manifest**, never in CSS. This keeps every stack consistent and lets the daemon use native macOS surfaces (Liquid Glass, vibrancy) that CSS can't reproduce.

## `material`

Set `material` in `stack.json` (`Sources/StackMaterial.swift`):

| Manifest value | Result |
|---|---|
| missing / `null` / `"none"` | No material — fully transparent panel |
| `"glass"` | Liquid Glass, regular (macOS 26; falls back to HUD vibrancy on older OSes) |
| `"glass.clear"` | Liquid Glass, clear variant |
| `"glass.tinted(#RRGGBB)"` | Tinted Liquid Glass (accepts `#RRGGBB` or `#RRGGBBAA`) |
| `"vibrancy.<key>"` | `NSVisualEffectView` material — keys: `sidebar`, `hud`, `popover`, `menu`, `titlebar`, `sheet`, `window`, `header`, `selection` |
| legacy bare aliases (`"sidebar"`, `"hud"`, …) | Same vibrancy materials, kept for back-compat |
| unknown string / bad hex | Falls back to `none` and logs a warning — never crashes |

```json
{ "material": "glass.tinted(#1E90FF)", "cornerRadius": 16 }
```

## Corner radius & shape

- `cornerRadius` (a number) rounds the panel. It applies to any material, including `none`.
- `shape: "capsule"` makes a pill/circle by deriving the radius from `min(w,h)/2`, ignoring `cornerRadius`.

## The auto-padding contract

On a **glass** material with `cornerRadius > 0` and **no explicit `padding`**, the daemon auto-injects `body { padding: cornerRadius / 2 }`. The inset matches the inner WebView's corner so content sits neatly inside the glass rim without each stack hand-tuning it.

- An **explicit manifest `padding` (even `0`) is used verbatim** and wins.
- **Full-bleed content** (SVG, canvas, edge-to-edge imagery) must set `"padding": 0` **in the manifest** — not in CSS. The manifest injection is last-cascade-wins, so a CSS rule would be overridden.

```json
{ "material": "glass", "cornerRadius": 20, "padding": 0 }
```

## CSS restrictions

Two rules keep the native material looking right:

1. **Do not use `backdrop-filter` / `-webkit-backdrop-filter`** (or rgba blur overlays) in stack CSS. The daemon's material already provides the glass/blur, and the WebView is composited transparently on top of it. Adding CSS blur double-blurs and breaks the effect.
2. **Glass panels have no drop shadow** (`hasShadow = false`) by design. Don't try to fake one to "fix" it.

## Placement

`region`, `anchor`, `size`, `display`, and `level` control where and how the panel sits — full details in the [Manifest reference](../reference/manifest.md). Quick orientation:

- `anchor.edge` pins to a corner/edge/center; `anchor.inset` is `[y, x]` in points.
- `region: "menubar"` spans the menu bar; `region: "fullscreen"` covers the whole screen.
- `display: "all"` spawns one instance per screen.
- `level` sets stacking order (`bar` < `overlay` < `tooltip` < `cursor`).

## Runtime adjustments

A stack can move/restyle its own panel at runtime via [`sd.window`](../reference/api.md#sdwindow--this-stacks-panel--self-scoped):

```js
await sd.window.setFrame({ x: 100, y: 100, w: 300, h: 80 });
await sd.window.setAlpha(0.6);
await sd.window.setClickThrough(false);
```

## See also

- [Manifest reference](../reference/manifest.md) — every chrome field
- [Lifecycle & rules](lifecycle-and-rules.md) — never-frontmost and other invariants
