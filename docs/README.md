# stackd — author documentation

stackd is a macOS daemon that runs **stacks**: web pages (HTML/CSS/JS + a `stack.json` manifest) shown in panels over the desktop. A stack reads live macOS state and drives macOS capabilities — windows, battery, audio, pointer, network, calendar, sensors, and more — through the `sd.*` API, in plain web tech.

A stack is a folder in `~/stackd/stacks/<id>/`. The minimum is two files:

`stack.json`
```json
{
  "id": "battery-hud",
  "name": "Battery HUD",
  "anchor": { "edge": "top-right", "inset": [16, 16] },
  "size": { "w": 150, "h": 44 },
  "material": "glass",
  "cornerRadius": 16,
  "permissions": []
}
```

`index.html`
```html
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; display:flex; align-items:center; justify-content:center;
         height:100vh; font:600 15px system-ui; color:#fff; }
</style></head>
<body>
  <div>🔋 {{ sd.battery.percent }}%{{ sd.battery.charging ? ' ⚡' : '' }}</div>
</body></html>
```

`stackd reload` picks it up. `permissions` stays empty because the daemon infers `battery` from the `{{ sd.battery }}` you reference.

## Documentation

**Start here**

- [Getting started](getting-started.md) — build a stack from scratch; the ways to read and act on state.

**Concepts** — how the pieces work

- [The reactive model](concepts/reactive-model.md) — channels, bangs, requests, replay on load.
- [Permissions](concepts/permissions.md) — inference, composite permissions, the macOS consent prompts to expect.
- [Chrome & material](concepts/chrome-and-material.md) — glass/vibrancy, corner radius, the padding contract, placement.
- [Lifecycle & rules](concepts/lifecycle-and-rules.md) — where stacks live, reload, and the daemon-enforced invariants.

**Reference** — the exhaustive surface

- [Manifest (`stack.json`)](reference/manifest.md) — every field, plus the hotkey and eventtap grammars.
- [Template engine](reference/template-engine.md) — `{{ }}`, `sd-each`, `sd-if`, `sd-on:click`, `sd.bind`, `sd.tpl`.
- [`sd.*` API](reference/api.md) — every namespace, method, and channel.

---

*Generated against the source (`Runtime/api.js`, `Sources/Channels.swift`, `Sources/Permissions.swift`, the manifest parser). If anything here disagrees with the daemon, the daemon is right — please file it.*
