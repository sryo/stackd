# How stackd works inside

The README tells people what stackd does. This page keeps the how: the history, the macOS frameworks behind each `sd.*` area, the vocabulary in its strict sense, and where things live on disk.

## History

stackd is the successor to a Hammerspoon config that grew too tall. The native parts stay native (Accessibility, eventtaps, IOKit, CGEvent post); the visual layer is HTML/CSS — the same tools, the same dev tooling, the same gradients you can already write — instead of a paint-program's worth of `hs.canvas` arithmetic.

## Vocabulary

Everything in the docs uses these terms in the strict sense.

**Units**
- **stack** — a loadable folder (`~/stackd/stacks/<id>/`) with a manifest (`stack.json`), a rendered surface (`index.html` + `index.css`), and optional permissions. The deployable unit.
- **manifest** — `stack.json`. Declares region, size, anchor, material, permissions, handles, hotkeys, eventtap entries. `Sources/StackTemplates.swift` has the full schema; [the manifest reference](reference/manifest.md) documents every field.
- **panel** — the borderless NSPanel the daemon creates to host a stack's WKWebView. One stack = one panel (per display, for fullscreen stacks).

**The reactive surface (what a stack sees)**
- **primitive** — any general `sd.*` API. Every primitive has at least two unrelated callers (no `sd.spotify` — there's `sd.media`).
- **channel** — a top-level `sd.*` namespace (`sd.battery`, `sd.windows`, `sd.media`). The unit of permission inference.
- **signal** — reactive state. `sd.battery`, `sd.mouse`, `sd.windows.focused`. Subscribe or drop into `{{ }}`; the panel re-renders on change.
- **action** — one-shot async write. `sd.windows.setFrame(...)`, `sd.pasteboard.set(...)`. Opposite of signal.
- **bang** — one-shot pub/sub topic event. Any stack can fire (`sd.bang`); any stack that lists the topic in `handles` receives. CLI: `stackd bang my.topic key=value`. JS: `window.onBang_my_topic = (detail) => {…}`.

**Native plumbing (daemon-side)**
- **observer** — a daemon-side poller backing a signal (`BatteryObserver`, `AudioObserver`). Sheds itself when no stack subscribes.
- **scope** / **StackScope** — per-stack container of native resources (observer subs, hotkeys, eventtaps). Drains in reverse on unload — nothing leaks, and a leak surfaces in teardown order.
- **token** — a cancellable handle returned by registries, adopted into a StackScope.
- **hotkey** — Carbon system-wide keybinding. Manifest-declared (`hotkeys: [...]`) or dynamic (`sd.hotkey.bind`).
- **eventtap** — CGEventTap subscription. Manifest-declared, read-only or consuming, including private gesture decoding.

**CLI**
- **verb** — a `stackd` subcommand. The `stackd` binary is both daemon and client; with no arguments it starts the daemon, with arguments it sends them to the running daemon. `new`, `doctor` and `help` run locally.

**Permissions** (BELIEFS #6 — reads inferred, writes declared)
- Channel reads are auto-inferred from `sd.<channel>` references in your HTML/CSS/JS — the list is usually a *minimum* you don't have to maintain.
- Actions that change the world (e.g. `menubar.item`, `overlay`) must be listed explicitly.

## Template engine internals

The runtime walks the DOM at load time, finds every `{{ … }}` (in text *and* attributes), and re-renders whenever any `sd.*` signal it touches changes.

Signal detection is regex-based, so a placeholder must name a signal by its full path (`{{ sd.battery.percent }}`, not `const b = sd.battery; b.percent`). Nested `sd-each` is not supported — the runtime warns and skips the inner one.

## Frameworks behind `sd.*`

| API | Backed by |
|---|---|
| `sd.sensors` | IOHIDEventSystem |
| `sd.displayLink` | vsync-locked frame tick (60/120 Hz, matches the display) |
| `sd.touchdevice` | MultitouchSupport (private) |
| `sd.disks.list()` | DiskArbitration |
| `sd.windows.*` | Accessibility, addressed by AX element or CGWindowID |
| `sd.spaces.*` | SkyLight SPI |
| `sd.overlay.attach` | an overlay panel pinned to another app's window (the JankyBorders pattern) |
| `sd.menubar.suppress` | SkyLight menu-bar alpha override |
| `sd.menubar.addItem` | NSStatusItem |
| `sd.menu.popup` | NSMenu |
| `sd.mouse` | sampled at 30 Hz, change-detected |
| `sd.input.layout` | Text Input Sources (TIS) |
| `sd.events.*` | CGEvent post |
| `sd.hotkey.*` | Carbon hotkeys; modal keymaps follow skhd |
| `sd.app.frontmost` | NSWorkspace |
| `sd.net.lan` | SCDynamicStore + Bonjour |
| `sd.net.path` | NWPathMonitor |
| `sd.media.*` | MediaRemote SPI |
| `sd.speech.speak` | AVSpeechSynthesizer |
| `sd.sound.*` | NSSound |
| `sd.fs.watch` | FSEvents |
| `sd.applescript.run` | NSAppleScript |
| `sd.defaults.read` | CFPreferences |
| `sd.settings.*` | a UserDefaults suite per stack |
| `sd.sqlite.*` | embedded libsqlite3 (FTS4/FTS5) |
| `sd.broadcasts.subscribe` | NSDistributedNotificationCenter |
| `sd.vision.*` | Vision |
| `sd.nlp.*` | NaturalLanguage |
| `sd.spotlight.find` | NSMetadataQuery (`kMDItem*` filters) |
| `sd.calendar.*` | EventKit |

`stackd doctor` also checks that every private SkyLight function stackd calls still exists on this macOS, since a missing one makes its primitive silently do nothing.

## Hot reload

FSEvents watches `~/stackd/stacks/`, `~/stackd/defaults.json`, and the runtime. Any save triggers a reload within ~300ms. When a stack's HTML fails to load, the panel stays visible-but-empty instead of vanishing — easier to spot than a silent hide. The daemon logs to stderr (`~/Library/Logs/stackd.log` under launchd).

## CLI transport

The CLI talks to the running daemon over a Unix socket at `~/Library/Application Support/stackd/daemon.sock`. A pidfile at `~/Library/Application Support/stackd/daemon.pid` keeps it a singleton, so it's safe to invoke from shell scripts, skhd, Karabiner.

## The primitive discipline

Every API in `sd.*` is a *general primitive* with at least two real consumers. No `sd.spotify` — there's `sd.media`, and Spotify is one feed of many (Apple Music, browser PiPs, Podcasts). No `sd.dock_orientation` — there's `sd.defaults.read("com.apple.dock", "orientation")`. If you find yourself wanting an escape hatch, propose the primitive that generalizes it.

## Project layout

```
~/stackd/                     ← user content
  defaults.json               ← global manifest defaults
  stacks/
    <id>/
      stack.json
      index.html
      index.css

~/Documents/stackd/           ← project source (this repo)
  Sources/                    ← Swift host + data sources
  Runtime/src/                ← the sd.* JavaScript runtime, one module per area;
                                build.sh concatenates it into the generated Runtime/api.js
                                that the daemon serves next to the binary
  Tests/                      ← test suite (./tests.sh)
  build.sh                    ← swiftc one-shot
  .build/stackd               ← binary
  examples/                   ← reference stacks, one folder each

~/Library/Application Support/stackd/
  daemon.sock                 ← CLI ↔ daemon Unix socket
  daemon.pid                  ← singleton guard
```

## Foundations

The substrate is whatever macOS already ships — Accessibility, IOKit, CGEvent, FSEvents, WebKit, CoreAudio, MultitouchSupport, AVFoundation, EventKit, Vision, NaturalLanguage. When Apple has a public API, stackd uses it; when only an SPI exists (DisplayServices, MediaRemote, SkyLight, MultitouchSupport), the header is vendored explicitly so the dependency is visible in the source tree. No kernel extensions, no privileged helpers, no daemons that aren't this one.

The daemon never becomes frontmost: panels are `.nonactivatingPanel` only, and there are no `NSApp.activate` calls.
