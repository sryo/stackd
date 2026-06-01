# stackd

A small macOS daemon for making your computer feel like yours.

Drop a folder into `~/stackd/stacks/` and it becomes a live piece of your desktop — a status strip across the top, a launcher you summon with a hotkey, a script that fires when you close a window. The folder is a *stack*: a `stack.json`, an `index.html`, an `index.css`. stackd renders it in a transparent WKWebView and feeds it system state through a small JavaScript API.

It's the successor to a Hammerspoon config that grew too tall. The native parts stay native (Accessibility, eventtaps, IOKit, CGEvent post); the visual layer is HTML/CSS — the same tools, the same dev tooling, the same gradients you can already write — instead of a paint-program's worth of `hs.canvas` arithmetic.

```
~/stackd/stacks/battery/
├── stack.json         { "anchor": { "edge": "top-right", "inset": [16, 16] },
│                        "size":   { "w": 140, "h": 64 } }
├── index.html         <div id="pct">{{ sd.battery.percent }}%</div>
└── index.css
```

## Contents

- [Install](#install) · [Quick start](#quick-start) · [Concepts](#concepts)
- [Writing a stack](#writing-a-stack) — templates, scripts, manifest fields
- [System data (`sd.*`)](#system-data-sd) — what stacks can read and do
- [CLI](#cli) · [Hot reload](#hot-reload) · [Examples](#examples)
- [Status](#status) · [Project layout](#project-layout) · [Lineage](#lineage)

## Install

Requires macOS 14+. Build from source:

```
git clone <this repo> ~/Documents/stackd
cd ~/Documents/stackd
./build.sh
.build/stackd                                # starts the daemon
```

On first launch stackd asks for **Accessibility** (hotkeys, event taps, window focus reads). Grant in System Settings → Privacy → Accessibility. The user folder `~/stackd/` is created automatically — your stacks live under `~/stackd/stacks/<name>/`.

## Quick start

```
stackd new hello
```

Scaffolds `~/stackd/stacks/hello/` — three files, a transparent panel in your top-right showing the current battery percent and theme. FSEvents picks it up within ~300ms; no build step. Edit `index.html`, save, watch it change.

```html
<!doctype html><meta charset="utf-8">
<div>{{ sd.battery.percent }}%</div>
```

That's a complete stack body. The runtime walks the DOM at load time, finds every `{{ … }}` (in text *and* attributes), and re-renders whenever any `sd.*` signal it touches changes.

## Concepts

- **stack** — a loadable folder (`~/stackd/stacks/<id>/`) or single file (`~/stackd/stacks/<id>.stack`). Has a manifest (`stack.json` or frontmatter), a rendered surface (`index.html` + `index.css`), and optional permissions.
- **signal** — reactive system state. `sd.battery`, `sd.mouse`, `sd.windows.focused`. Subscribe or drop into `{{ }}`; the panel re-renders on change.
- **bang** — a message any stack can fire and any stack can handle. CLI: `stackd bang my.event key=value`. JS: `window.onBang_my_event = (detail) => {…}`.
- **verb** — a CLI command (`list`, `reload`, `toggle`, `set`, `bang`, `new`, `doctor`, `help`). The `stackd` binary is both the daemon and the client; arguments mean "send to the running daemon."
- **permission** — `stack.json` declares which `sd.*` channels the stack uses. Channel permissions are auto-inferred from `sd.<channel>` references in your HTML/CSS/JS, so the list is usually a *minimum* you don't have to maintain. RPC actions (e.g. `menubar.item`, `overlay`) still need to be listed explicitly.

## Writing a stack

A stack is `stack.json` + `index.html` + `index.css`. The manifest says where the panel lives and what it can touch:

```json
{ "id": "cursor", "name": "Cursor",
  "anchor": { "edge": "top-right", "inset": [16, 16] },
  "size":   { "w": 140, "h": 48 },
  "permissions": ["mouse"] }
```

Anchor edges are the eight standard corners + sides (`top-right`, `top-left`, `top`, `bottom`, `left`, `right`, …). Manifest also takes `region` (`fullscreen` for overlays), `clickThrough`, `invocable` (for hotkey-summoned panels), `hotkeys`, `handles`, and `material` (NSVisualEffectView under the WebView). See `Sources/StackTemplates.swift` for the full schema.

The single-file form drops the folder for trivial stacks:

```
~/stackd/stacks/hello.stack
```

Frontmatter on top (YAML or JSON), HTML body underneath. Same manifest fields, same runtime.

### Templates: `{{ }}` and `sd-each`

For putting a value on screen, write the expression in HTML. No `<script>`, no import, no callback:

```html
<div>{{ sd.mouse.x }}, {{ sd.mouse.y }}</div>
```

`sd-each="<array-expr>"` clones the element per item. `item` and `index` are in scope inside any `{{ }}` on the element or its descendants:

```html
<ul>
  <li sd-each="sd.usb">{{ item.productName }} ({{ item.vendorName }})</li>
</ul>
```

`sd-if="<expr>"` conditionally renders. Expressions are null-safe — if anything in the chain is `undefined`, the result is `""` rather than an error.

Runtime limits (v1): signal detection is regex-based, so refer to signals by full path (`{{ sd.battery.percent }}`, not `const b = sd.battery; b.percent`). Nested `sd-each` is not supported — the runtime warns and skips inner.

### Scripts: when you need more

Reach for a `<script>` when you need async work, event handlers, state machines, or list transforms beyond simple filtering:

```html
<div id="t"></div>
<script type="module">
  import { sd } from "sd://runtime/api.js";
  sd.bind(t, sd.mouse, m => m ? `${m.x}, ${m.y}` : "…");
</script>
```

`sd.bind(target, signal, fmt?)` covers the common case (textContent, innerHTML, attributes, CSS vars, class toggles). For anything else, signals are subscribable: `sd.battery.subscribe(b => …)`. Template + script forms work side-by-side in the same stack.

`stackd doctor` checks every manifest in `~/stackd/stacks/` for missing fields, typo permissions, and a few other footguns.

## System data (`sd.*`)

Available inside `{{ }}` templates and `import { sd } from "sd://runtime/api.js"` in scripts. Reactive *signals* are subscribable / re-render on change; *actions* are one-shot async calls.

### Hardware

| API | What it gives you |
|---|---|
| `sd.battery` | % + charging + cycles + health + amperage + voltage + timeRemaining |
| `sd.sensors` | per-die temps, per-rail voltage/current, fan RPM (IOHIDEventSystem) |
| `sd.host.info()` / `sd.host.load` | hostname/os/arch/cpu/ram; live CPU/GPU/memory/swap/idle |
| `sd.caffeinate` | `{ sleeping, locked }` — system sleep + screen lock signal |
| `sd.displayLink` | vsync-locked frame tick (60/120 Hz, matches display) |
| `sd.touchdevice` | raw per-finger trackpad frames via MultitouchSupport |
| `sd.bluetooth.paired()` | paired peripherals + connection state + services |
| `sd.usb` | attached USB devices, fires on attach/detach |
| `sd.disks.list()` | mounted volumes (DiskArbitration) |
| `sd.location` | GPS-style fix `{ lat, lon, accuracy, … }` (needs Location grant) |

### Display & windows

| API | What it gives you |
|---|---|
| `sd.display.all` / `sd.display.setBrightness` / `sd.display.snapshot()` | per-display info; brightness; pixel capture |
| `sd.appearance` | dark/light + accent color |
| `sd.windows.focused` / `sd.windows.all` | focused window of frontmost app; every on-screen window |
| `sd.windows.setFrame / minimize / fullscreen / raise / focus / close / cornerRadius / snapshot / batch` | per-window actions (by AX or CGWindowID) |
| `sd.spaces.all` / `sd.spaces.windowSpaces(id)` / `sd.spaces.minimizedWindows(spaceID)` | Spaces info via SkyLight SPI |
| `sd.overlay.attach(windowId, draw)` | CG-context overlay pinned to another app's window (JankyBorders pattern) |
| `sd.menubar.suppress / restore` | hide/restore system menu bar |
| `sd.menubar.addItem(spec)` | add an NSStatusItem |
| `sd.menu.popup(items)` | native NSMenu at the cursor |

### Input

| API | What it gives you |
|---|---|
| `sd.mouse` | cursor x,y at 30 Hz (change-detected) |
| `sd.cursor.setPosition({x,y}) / position()` | warp / read (top-left global, optional per-display) |
| `sd.input.layout` | active keyboard layout (TIS) |
| `sd.events.type / key / scroll / click` | synthesize input via CGEvent post |
| `sd.hotkey.bind(spec, fn, opts)` / `sd.hotkey.mode.*` | dynamic Carbon hotkeys + modal keymaps (skhd parity) |

### Apps & UI

| API | What it gives you |
|---|---|
| `sd.app.frontmost` | frontmost app (NSWorkspace) |
| `sd.apps.running` / `sd.apps.changed` | full list signal; transition deltas |
| `sd.apps.launch / focus / kill / hide` | by bundle ID |
| `sd.ax.focused()` + generic `sd.ax.*` | Accessibility tree access (handles, attributes, actions) |
| `sd.icons.app(bundleId) / file(path)` | app + file icons as data URLs |

### Network

| API | What it gives you |
|---|---|
| `sd.net.wifi` | SSID + signal (needs Location grant for SSID) |
| `sd.net.lan` | primary IPv4 + hostname (SCDynamicStore + Bonjour) |
| `sd.net.path` | NWPathMonitor — `{ status, interfaces, isConstrained, isExpensive }` |
| `sd.httpserver.serve({port, routes, …})` | long-running HTTP server (loopback or LAN + optional Bonjour) |

### Audio, media, output

| API | What it gives you |
|---|---|
| `sd.audio.output` / `sd.audio.setVolume / setMuted` | output volume + device |
| `sd.media.nowPlaying` / `sd.media.command(name)` | Spotify/Music/Podcasts/browser (MediaRemote SPI) |
| `sd.speech.speak / stop / voices()` | AVSpeechSynthesizer TTS |
| `sd.sound.system / file / beep` | short NSSound playback |
| `sd.notify.show(spec)` | banner notification |

### Files, processes, persistence

| API | What it gives you |
|---|---|
| `sd.fs.read / stat / list / write / mkdir / delete / move / watch` | atomic FS access + FSEvents watcher |
| `sd.proc.exec(cmd, args, opts)` | one-shot subprocess |
| `sd.applescript.run(source, opts)` | NSAppleScript (AppleScript / JXA) |
| `sd.shortcuts.run(name, opts)` | invoke a macOS Shortcut by name |
| `sd.defaults.read(bundleId, key)` | CFPreferences for any app |
| `sd.settings.get / set / delete / all` | per-stack k/v (UserDefaults suite) |
| `sd.sqlite.open(path)` → `.exec / query / close` | embedded libsqlite3 (FTS4/FTS5) |
| `sd.pasteboard.changed` / `sd.pasteboard.get / set` | clipboard contents signal + r/w |

### Intelligence

| API | What it gives you |
|---|---|
| `sd.vision.ocr / faces / featurePrint / subjectMask / bodyPose` | Apple Vision framework |
| `sd.nlp.language / tokens / lemmas / similarity` | NaturalLanguage framework |
| `sd.spotlight.find({predicate, …})` | NSMetadataQuery — `kMDItem*` filters |
| `sd.calendar.events({from, to}) / calendar.list()` | EventKit reads (needs Calendar grant) |
| `sd.camera` (signal) / `sd.camera.frame(opts)` | device list (no TCC); `.frame()` triggers Camera prompt |

### Stack control

| API | What it gives you |
|---|---|
| `sd.bang(name, detail)` | fire a bang to every stack whose manifest `handles` it |
| `sd.broadcasts.observe(name, fn)` | NSDistributedNotificationCenter observer |
| `sd.window.invoke() / dismiss()` | show/hide stacks declared `invocable` (palette pattern) |

Window lifecycle (`sd.window.created / destroyed / titleChanged / moved / resized / minimized / deminimized / reordered / focusedByMouse`) and disk mount/unmount fire as bangs — declare in `stack.json`:

```json
{ "handles": ["sd.window.destroyed", "sd.disk.mounted"] }
```

Hotkeys (Carbon) and event taps (CGEventTap, incl. private gesture decoding) are also declared in the manifest. See `examples/` for working patterns.

## CLI

```
stackd                                            start the daemon (no args)
stackd list                                       list loaded stacks
stackd reload                                     tear down + re-discover from disk
stackd toggle <id>                                enable / disable a single stack
stackd set <id|/regex/> --css <prop>=<value>      live theme override
stackd bang <name> [KEY=VAL ...]                  fire a bang
stackd new <name> [--template <hello|menubar|hud>]
                                                  scaffold a new stack
stackd doctor                                     validate every manifest
stackd help
```

Selectors: `<id>` is exact; `/pattern/` is a regex. `defaults.json` at the stackd root is shallow-merged under every stack manifest before decoding — useful for global anchors, materials, permissions.

The CLI talks to the running daemon over a Unix socket at `~/Library/Application Support/stackd/daemon.sock`. Pidfile-guarded singleton; safe to invoke from shell scripts, skhd, Karabiner. `new` and `doctor` are local file ops and work without the daemon.

## Hot reload

FSEvents watches `~/stackd/stacks/`, `~/stackd/defaults.json`, and the runtime. Any save triggers a reload within ~300ms. No build step. Edit a CSS file, save, see the change.

## Examples

`examples/` ships ~30 working stacks covering most of the surface above. A few starting points:

- **`hello`** — the scaffolder output, three-file template panel.
- **`menubar-item`** — `sd.menubar.addItem` for NSStatusItem widgets with submenus.
- **`invocable-palette`** — hotkey-summoned overlay + AX reads + fuzzy app search.
- **`fs-watcher`** — `sd.fs.watch` driving live UI.
- **`bang-pair`** — two stacks talking via bangs.
- **`overlay-border`** — `sd.overlay.attach` painting a focused-window border (JankyBorders).
- **`sysinfo`** / **`sensors-test`** / **`displaylink-test`** — sampling the harder signals.

Copy any of them into `~/stackd/stacks/` to play with.

## Status

Working and in daily use:

- **HS ports** — `notunes`, `apptimeout`, `palette`, `timetrail`, `undoclose`, `autodmg`, `sideswipe`, `muse`, `cloudpad`, `digup`, `edgehopper`, `framecorners`, `tttaps`, `windowscape`.
- **Display stacks** — `bar`, `sysinfo`, `framecorners`, `overlay-border`.

The discipline: every API in `sd.*` is a *general primitive* with at least two real consumers. No `sd.spotify` — there's `sd.media`, and Spotify is one of many publishers. No `sd.dock_orientation` — there's `sd.defaults.read("com.apple.dock", "orientation")`. If you find yourself wanting an escape hatch, propose the primitive that generalizes it.

Open items: STT (`sd.speech.listen`), AirPods battery, camera stream, calendar writes + reminders, modern menu-bar suppress API on Sequoia+ (CGSSetMenuBarVisibility removed), per-AX-observer parity, AX notification bus (`sd.ax.observe`).

## Project layout

```
~/stackd/                     ← user content
  defaults.json               ← global manifest defaults
  Runtime/api.js              ← (symlinked from .build/Runtime/ in dev; bundled in prod)
  stacks/
    <id>/                     ← folder format
      stack.json
      index.html
      index.css
    <id>.stack                ← single-file format (frontmatter + body)

~/Documents/stackd/           ← project source (this repo)
  Sources/                    ← Swift host + data sources
  Runtime/                    ← stdlib (api.js) — ships next to the binary
  build.sh                    ← swiftc one-shot
  .build/stackd               ← binary
  examples/                   ← ~30 reference stacks

~/Library/Application Support/stackd/
  daemon.sock                 ← CLI ↔ daemon Unix socket
  daemon.pid                  ← singleton guard
```

## Lineage

`hs.canvas` and `hs.drawing` from Hammerspoon. `--item` and `--message` from SketchyBar. `stacks` from HyperCard. `bangs` from LiteStep. `signals` from Solid/Preact. `defaults.json` from SketchyBar's `--default`. The private SPI vendoring pattern (DisplayServices, MediaRemote, SkyLight, MultitouchSupport) from every macOS power-user tool that ever wanted to do something Apple didn't bless.
