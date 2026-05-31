# stackd examples

Each folder is a working stack you can drop into `~/stackd/stacks/` to try.

```sh
cp -r examples/hello ~/stackd/stacks/hello
```

FSEvents picks it up; the panel appears within ~300ms.

| Example | Demonstrates |
|---|---|
| [hello](hello) | Minimal panel — `sd.bind`, two signals, three target shapes |
| [menubar-item](menubar-item) | `sd.menubar.addItem` with a dynamic icon and menu |
| [fs-watcher](fs-watcher) | `sd.fs.watch` + a banged message to other stacks |
| [bang-pair](bang-pair) | Two stacks communicating via `sd.bang` |
| [invocable-palette](invocable-palette) | `invocable: true`, hotkey-summoned overlay, `sd.ax.focused` |
| [sound-test](sound-test) | `sd.sound.system`, `sd.sound.file`, `sd.sound.beep` on hotkeys |
| [applescript-test](applescript-test) | `sd.applescript.run` — AppleScript + JXA with success / error handling |
| [broadcasts-test](broadcasts-test) | `sd.broadcasts.observe` — Distributed Notifications (lock / unlock) |
| [camera-test](camera-test) | `sd.camera` device list with `isInUse` highlight |
| [corner-dot](corner-dot) | Pure-manifest panel — `display: all`, `anchor`, no script |
| [cursor](cursor) | `sd.mouse` live coords + `sd.bang` flash via `user.beep` |
| [focus](focus) | `sd.app.frontmost` + `sd.windows.focused` title |
| [gesture](gesture) | `eventtap: gesture` — pinch/swipe/rotate name and finger count |
| [glass-material-test](glass-material-test) | `"material": "glass"` — native NSVisualEffectView background |
| [host-test](host-test) | `sd.host.info` + `sd.host.load` — uptime, CPU %, memory |
| [keypress](keypress) | `eventtap: keyDown` + `flagsChanged` — keycode and modifier glyphs |
| [location-test](location-test) | `sd.location.subscribe` — Core Location lat/lon + accuracy |
| [nlp-test](nlp-test) | `sd.nlp.language` / `tokens` / `lemmas` / `similarity` |
| [sensors-test](sensors-test) | `sd.sensors` — temperatures, voltages, fans via IOHIDEventSystem |
| [sysinfo](sysinfo) | `sd.input.layout`, `sd.net.wifi`/`lan`, `sd.audio.output`, `sd.display.all`, `sd.appearance`, `sd.defaults.read` |
| [touchdevice-test](touchdevice-test) | `sd.touchdevice` — per-finger frames with stable IDs |
| [usb-test](usb-test) | `sd.usb` device list with hot-plug updates |

Once you've copied one, `stackd doctor` validates the manifest. `stackd new <name>` scaffolds a fresh `hello`-style stack from the same template.
