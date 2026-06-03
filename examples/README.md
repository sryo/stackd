# stackd examples

Each folder is a working stack you can drop into `~/stackd/stacks/` to try.

```sh
cp -r examples/hello ~/stackd/stacks/hello
```

FSEvents picks it up; the panel appears within ~300ms.

| Example | Demonstrates |
|---|---|
| [applescript-test](applescript-test) | `sd.applescript.run` — AppleScript + JXA with success / error handling |
| [bang-pair](bang-pair) | Two stacks communicating via `sd.bang` |
| [broadcasts-test](broadcasts-test) | `sd.broadcasts.observe` — Distributed Notifications (lock / unlock) |
| [camera-test](camera-test) | `sd.camera` device list with `isInUse` highlight |
| [corner-dot](corner-dot) | Pure-manifest panel — `display: all`, `anchor`, no script |
| [cursor](cursor) | `sd.mouse` live coords + `sd.bang` flash via `user.beep` |
| [cursor-warp-test](cursor-warp-test) | `sd.cursor.setPosition` — warp cursor to coords or display origin |
| [display-snapshot-test](display-snapshot-test) | `sd.display.snapshot` — ScreenCaptureKit grab on a hotkey |
| [displaylink-test](displaylink-test) | `sd.displayLink` — vsync-locked frame ticks (60 / 120Hz) |
| [eventtap-consume-test](eventtap-consume-test) | `eventtap` with `consume: true` — swallow Space and fire the callback |
| [focus](focus) | `sd.app.frontmost` + `sd.windows.focused` title |
| [fs-watcher](fs-watcher) | `sd.fs.watch` + a banged message to other stacks |
| [gesture](gesture) | `eventtap: gesture` — pinch/swipe/rotate name and finger count |
| [glass-material-test](glass-material-test) | `"material": "glass.clear"` — Liquid Glass (NSGlassEffectView, macOS 26+) |
| [hello](hello) | Minimal panel — `sd.bind`, two signals, three target shapes |
| [host-test](host-test) | `sd.host.info` + `sd.host.load` — uptime, CPU %, memory |
| [hotcorners-test](hotcorners-test) | `manifest.hotcorners` — corner enter / exit callbacks with `sd.notify` |
| [httpserver-test](httpserver-test) | `sd.httpserver.serve` — loopback HTTP routes with JS handlers |
| [invocable-palette](invocable-palette) | `invocable: true`, hotkey-summoned overlay, `sd.ax.focused` |
| [keypress](keypress) | `eventtap: keyDown` + `flagsChanged` — keycode and modifier glyphs |
| [location-test](location-test) | `sd.location.subscribe` — Core Location lat/lon + accuracy |
| [menubar-item](menubar-item) | `sd.menubar.addItem` with a dynamic icon and menu |
| [mousemoved-test](mousemoved-test) | `eventtap: mouseMoved` — live deltas + cursor position |
| [nlp-test](nlp-test) | `sd.nlp.language` / `tokens` / `lemmas` / `similarity` |
| [overlay-border](overlay-border) | `sd.overlay.attach` — focused-window accent border via SLS overlay |
| [sensors-test](sensors-test) | `sd.sensors` — temperatures, voltages, fans via IOHIDEventSystem |
| [sound-test](sound-test) | `sd.sound.system`, `sd.sound.file`, `sd.sound.beep` on hotkeys |
| [sqlite-test](sqlite-test) | `sd.sqlite.open` — open / exec / query / close round-trip |
| [sysinfo](sysinfo) | `sd.input.layout`, `sd.net.wifi`/`lan`, `sd.audio.output`, `sd.display.all`, `sd.appearance`, `sd.defaults.read` |
| [touchdevice-test](touchdevice-test) | `sd.touchdevice` — per-finger frames with stable IDs |
| [usb-test](usb-test) | `sd.usb` device list with hot-plug updates |
| [vision-ocr-test](vision-ocr-test) | `sd.display.snapshot` → `sd.vision.ocr` — text recognition pipeline |
| [windows-batch-test](windows-batch-test) | `sd.windows.batch` — atomic multi-window `setFrame` vs. naive loop |

Once you've copied one, `stackd doctor` validates the manifest. `stackd new <name>` scaffolds a fresh `hello`-style stack from the same template.
