# stackd

A small macOS daemon for making your computer feel like yours.

Drop a folder into `~/stackd/stacks/` and it becomes a live piece of your desktop — a status strip across the top, a launcher you can summon, a script that fires when you close a window. The folder is a *stack*: a `stack.json`, an `index.html`, an `index.css`. stackd renders it in a transparent WKWebView and feeds it system state through a small JavaScript API.

It's the successor to a Hammerspoon configuration that grew too tall. Everything you'd write in `hs.canvas` or `hs.eventtap` is now HTML/CSS and JS, with the daemon handling the parts that need to be native.

```
~/stackd/stacks/battery/
├── stack.json         { "anchor": { "edge": "top-right", "inset": [16, 16] },
│                        "size":   { "w": 140, "h": 64 },
│                        "permissions": ["battery", "appearance"] }
├── index.html         <script type="module">
│                        import { sd } from "sd://runtime/api.js";
│                        sd.battery.subscribe(b => {
│                          document.getElementById("pct").textContent = b.percent + "%";
│                        });
│                      </script>
└── index.css
```

## Install

Requires macOS 14+. Build from source:

```
git clone <this repo> ~/Documents/stackd
cd ~/Documents/stackd
./build.sh
.build/stackd                                # starts the daemon
```

On first launch stackd asks for **Accessibility** (for hotkeys, event taps, window focus reads). Grant in System Settings → Privacy → Accessibility.

The user folder `~/stackd/` is created automatically. Drop your stacks under `~/stackd/stacks/<name>/`.

## Your first stack

```
stackd new hello
```

Scaffolds `~/stackd/stacks/hello/` with three files (`stack.json`, `index.html`, `index.css`) — a transparent panel in your top-right showing the current battery percent and theme. FSEvents picks it up within ~300ms; no build step. Edit `index.html`, save, watch it change.

Every stack is the same three files. `stack.json` says where it lives on screen and what system data it's allowed to read (`permissions`). `index.html` is the markup, loaded into a transparent WKWebView. The `sd.*` namespace inside is the bridge to the daemon — `sd.battery`, `sd.windows.focused`, `sd.appearance` are *signals* you subscribe to with `sd.bind(...)`:

```html
<!doctype html><meta charset="utf-8">
<div id="t"></div>
<script type="module">
  import { sd } from "sd://runtime/api.js";
  sd.bind(t, sd.mouse, m => m ? `${m.x}, ${m.y}` : "…");
</script>
```

```json
{ "id": "cursor", "name": "Cursor",
  "anchor": { "edge": "top-right", "inset": [16, 16] },
  "size": { "w": 140, "h": 48 },
  "permissions": ["mouse"] }
```

When you're ready for something more, copy one of the [`examples/`](examples) folders into `~/stackd/stacks/`. `examples/menubar-item` shows `sd.menubar.addItem` for NSStatusItem widgets. `examples/invocable-palette` shows hotkey-summoned overlays + AX reads. `examples/fs-watcher` shows the filesystem API. `examples/bang-pair` shows two stacks talking via bangs.

`stackd doctor` checks every manifest in `~/stackd/stacks/` for missing fields, typo permissions, and a few other footguns.

## Concepts

- **stack** — a loadable folder. Has a manifest (`stack.json`), a rendered surface (`index.html` + `index.css`), and optional permissions.
- **signal** — reactive system state. `sd.battery`, `sd.mouse`, `sd.windows.focused`. Subscribe and re-render.
- **bang** — a message any stack can fire and any stack can handle. CLI: `stackd bang my.event key=value`. JS: `window.onBang_my_event = (detail) => {…}`.
- **verb** — a CLI command (`list`, `reload`, `toggle`, `set`, `bang`, `help`). The `stackd` binary is both the daemon and the client; arguments mean "send to the running daemon."

## What's in the daemon

System data exposed to stacks (via `import { sd } from "sd://runtime/api.js"`):

```
sd.battery              % + charging               (IOKit)
sd.mouse                cursor x,y at 30Hz         (NSEvent + change detection)
sd.appearance           dark/light + accent color  (NSDistributedNotificationCenter)
sd.audio                output volume + device     (CoreAudio)
sd.display.all          per-display info + bright. (NSScreen + DisplayServices private)
sd.input.layout         keyboard layout            (TIS)
sd.net.wifi             SSID + signal              (CoreWLAN — needs Location grant for SSID)
sd.net.lan              primary IPv4 + hostname    (SCDynamicStore + Bonjour)
sd.app.frontmost        frontmost app              (NSWorkspace)
sd.windows.focused      focused window of frontm.  (Accessibility — needs grant)
sd.windows.all          all on-screen windows      (CGWindowList)
sd.apps.running         running apps               (NSWorkspace.runningApplications)
sd.ax.focused           focused UI element + caret (Accessibility)
sd.media.nowPlaying     Spotify/Music/Podcasts/etc (MediaRemote private)
sd.pasteboard.changed   pasteboard contents        (NSPasteboard polling)
sd.icons                app + file icons → data URL (NSWorkspace)
sd.defaults.read        CFPreferences for any app
sd.fs                   read/stat/list + watch     (Foundation + FSEvents)
sd.proc.exec            one-shot subprocess        (Foundation Process)
sd.events.synthesize    type / key / scroll / click (CGEvent post)
sd.settings             per-stack k/v              (UserDefaults suites)
sd.window.invoke/dismiss invocable stacks (palettes)
sd.menubar.suppress     hide/restore system menu bar
sd.menubar.addItem      add an NSStatusItem to the menu bar
```

Window lifecycle (sd.window.created / destroyed / titleChanged) fires as bangs — declare in `stack.json`:

```json
{ "handles": ["sd.window.destroyed"] }
```

Hotkeys (Carbon) and event taps (CGEventTap incl. private gesture decoding) are also declared in the manifest. See `~/stackd/stacks/` for working examples.

## Verbs

```
stackd                                            start (no args)
stackd list                                       list loaded stacks
stackd reload                                     tear down + re-discover from disk
stackd toggle <id>                                enable / disable a single stack
stackd set <id|/regex/> --css <prop>=<value>      live theme override
stackd bang <name> [KEY=VAL ...]                  fire a bang to subscribed stacks
stackd new <name> [--template <hello|menubar|hud>]
                                                  scaffold a new stack
stackd doctor                                     validate every manifest
stackd help
```

The CLI talks to the running daemon over a Unix socket at `~/Library/Application Support/stackd/daemon.sock`. Pidfile-guarded singleton; safe to invoke from shell scripts, skhd, Karabiner.

## Hot reload

FSEvents watches `~/stackd/stacks/`, `~/stackd/defaults.json`, and the runtime. Any save triggers a reload within ~300ms. No build step. Edit a CSS file, save, see the change.

## Why this and not Hammerspoon

You could keep writing `hs.canvas` calls forever. But anything you want to look right requires a paint-program's worth of arithmetic, and the moment a theme uses a gradient you've already paid for someone else's CSS engine. stackd lets you write the visual layer in the same languages you already know, with the same dev tools, while keeping the parts that have to be native (AX, eventtap, CGEvent post, IOKit) in Swift where they belong.

The discipline: every API in `sd.*` is a *general primitive* with at least two real consumers. No `sd.spotify` — there's `sd.media`, and Spotify is one of many apps that publish to NowPlaying. No `sd.dock_orientation` — there's `sd.defaults.read("com.apple.dock", "orientation")`. If you find yourself wanting an escape hatch, propose the primitive that generalizes it.

## Status

Phases 0–3 shipped. Modules ported and validated:

- **notunes** — kills Music.app on launch (~10 lines)
- **apptimeout** — daily per-app time tracker with persisted state (~30 lines)
- **palette** — invocable launcher with fuzzy app search (~60 lines)
- **timetrail** — fading cursor trail on a fullscreen Canvas (~40 lines)
- **undoclose** — captures destroyed windows, reopens via Cmd+Shift+T (~50 lines)
- **bar / sysinfo / focus / cursor / battery / keypress / gesture / corner-dot** — demo stacks

Open items: `sd.spaces` (private SkyLight, untested on Sequoia+), `hotcorners` manifest field, per-window-id actions (need `_AXUIElementGetWindow` private SPI), TTTaps gesture-payload extension, modern menu-bar suppress API (CGSSetMenuBarVisibility removed on Sequoia+).

## Layout

```
~/stackd/                  ← user content
  defaults.json            ← global manifest defaults
  Runtime/api.js           ← (symlinked from .build/Runtime/ in dev; bundled in prod)
  stacks/
    <id>/
      stack.json
      index.html
      index.css

~/Documents/stackd/        ← project source (this repo)
  Sources/                 ← Swift host + data sources
  Runtime/                 ← stdlib (api.js) — ships next to the binary
  build.sh                 ← swiftc one-shot
  .build/stackd            ← binary

~/Library/Application Support/stackd/
  daemon.sock              ← CLI ↔ daemon Unix socket
  daemon.pid               ← singleton guard
```

## Lineage

`hs.canvas` and `hs.drawing` from Hammerspoon. `--item` and `--message` from SketchyBar. `stacks` from HyperCard. `bangs` from LiteStep. `signals` from Solid/Preact. `defaults.json` from SketchyBar's `--default`. The private SPI vendoring pattern (DisplayServices, MediaRemote, SkyLight) from every macOS power-user tool that ever wanted to do something Apple didn't bless.
