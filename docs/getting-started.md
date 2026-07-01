# Getting started

A stack is a folder of web files the daemon renders in a panel. This page sets one up, then covers the three ways to read live macOS state into it — simplest first.

## Set up a stack

Installed stacks live in **`~/stackd/stacks/<id>/`** (the repo's `examples/` folder is test scaffolding). A stack needs two files:

```
~/stackd/stacks/clock/
├── stack.json     ← manifest: identity, placement, look, capabilities
└── index.html     ← your HTML/CSS/JS
```

The smallest valid manifest is just identity:

```json
{ "id": "clock", "name": "Clock", "permissions": [] }
```

That alone renders an invisible 1px panel. Give it size, a place, and a material so you can see it — see [Chrome & material](concepts/chrome-and-material.md) for the full set:

```json
{
  "id": "clock",
  "name": "Clock",
  "anchor": { "edge": "top-center", "inset": [12, 0] },
  "size": { "w": 220, "h": 56 },
  "material": "glass",
  "cornerRadius": 18,
  "permissions": []
}
```

After any edit, run `stackd reload`.

## Three ways to read state

The point of a stack is reacting to macOS. There are three ways to bind a channel like `sd.battery`, and you'll mix them.

### 1. Templates (zero-config)

Put an expression in text or an attribute. It auto-updates when the channel pushes, and the daemon infers the permission from what you reference — no JavaScript, no manifest entry:

```html
<body>
  <div>🔋 {{ sd.battery.percent }}%{{ sd.battery.charging ? ' ⚡' : '' }}</div>
</body>
```

The expression is real JavaScript with `sd` in scope, so ternaries, `.toFixed(1)`, and `||` fallbacks all work. Lists and conditionals have their own attributes (`sd-each`, `sd-if`) — see the [Template engine](reference/template-engine.md).

> **Two limits of the template path**
> - **Aliased reads aren't tracked.** Dependency tracking scans the literal text for `sd.<channel>`, so `const b = sd.battery; b.percent` never re-renders. Use mode 2 for those.
> - **`sd-on:` handles only `click`** today, and `sd-each` doesn't nest. For anything past that, drop to a script.

### 2. `sd.bind` (reactive sugar)

When you want a formatter, or to drive an attribute/style/class instead of text, bind one element to a signal in a module script:

```html
<div id="readout"></div>
<script type="module">
  sd.bind(document.getElementById("readout"), sd.battery,
          b => b ? `${b.percent}% ${b.charging ? "⚡" : ""}` : "…");

  // Targets can be attributes, styles, or classes:
  sd.bind([document.body, "data-theme"], sd.appearance, a => a?.dark ? "dark" : "light");
  sd.bind([document.documentElement, "style.--accent"], sd.appearance, a => a?.accentHex || "#0a84ff");
</script>
```

### 3. `subscribe` (full control)

For arbitrary logic, subscribe directly. The callback fires once immediately with the current value, then on every change:

```html
<script type="module">
  sd.battery.subscribe(b => {
    document.body.classList.toggle("low", b && b.percent <= 20);
  });
</script>
```

You can also read once without subscribing — `sd.battery.peek()` — or await the first real value — `await sd.battery.first()`.

> **Don't poll.** Never `setInterval` to read macOS state. If you're polling, there's a channel you should subscribe to instead. See [Lifecycle & rules](concepts/lifecycle-and-rules.md#stacks-dont-poll).

## One stack, many primitives

A stack freely combines `sd.*` namespaces — each channel and method is independent. A window-manager stack might read `sd.windows`, `sd.spaces`, and `sd.display` together and call `sd.windows.batch(...)` to act; a HUD might mix `sd.battery`, `sd.audio`, and `sd.media`. Permissions accumulate from everything you reference.

```html
<div>{{ sd.audio.output.muted ? '🔇' : '🔊' }} {{ sd.audio.output.volume }}</div>
<div>{{ sd.media.nowPlaying.title || 'nothing playing' }}</div>
```

## Permissions, briefly

Every native capability is gated by a permission, but you rarely write the list — the daemon scans your HTML/JS and infers it from any `sd.<name>` you reference (that's why the examples above use `"permissions": []`). The one exception is **composite** permissions with extra side-effects, like `menubar.item`, which must be declared explicitly. Full story, including the macOS consent prompts to expect: [Permissions](concepts/permissions.md).

## Interactivity

Mark interactive elements and they capture their own clicks; with the default click-through panel, empty areas still pass through to the app behind. (A stack can also be fully interactive with `clickThrough: false`.)

```html
<button sd-on:click="sd.media.command('toggle')">⏯</button>
```

Global keyboard shortcuts and event taps are declared in the manifest (`hotkeys`, `eventtap`) — see the [Manifest reference](reference/manifest.md#hotkeys-entry).

## Next

- **Concepts** — [the reactive model](concepts/reactive-model.md) · [permissions](concepts/permissions.md) · [chrome & material](concepts/chrome-and-material.md) · [lifecycle & rules](concepts/lifecycle-and-rules.md)
- **Reference** — [manifest](reference/manifest.md) · [template engine](reference/template-engine.md) · [`sd.*` API](reference/api.md)
