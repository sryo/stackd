# Hero clip — storyboard

*Edit `index.html`, save, the desktop changes.* 12.3 s, loops, no sound.
Everything in frame is rendered by stackd: a fullscreen **stage** stack draws
the backdrop and a calm editor window; a real glass **widget** stack on the
right is hot-reloaded by the daemon each time the stage saves its files.

## Frame

- Capture rect: 1200×676 pt, centered on the primary display
  (`herotool geometry` → `captureX/Y`). Final GIF 1200 px wide (falls back
  to 1000 px if > 6 MB), MP4 1200×676 H.264 yuv420p.
- Editor window: x 48, y 95, 640×486, `#1e1e1e`, 12 px radius, static shadow.
  Code: SF Mono 22 px / 36 px line height, ≤ 12 lines, ≤ 40 chars per line
  (longest line is exactly 40). Palette: tags `#7ee787`, attributes/properties
  `#79c0ff`, strings `#a5d6ff`, `{{ expressions }}` `#ffa657`, punctuation
  `#8b949e`, hex colours in their own colour once six digits are typed.
- Widget (`hero-demo`): 320×180, `material: glass`, `cornerRadius: 24`,
  auto body padding 12, placed at frame (784, 248) — centered in the right
  third, vertically aligned with the editor's center.
- Backdrop: the shared gradient (`#0a84ff` top-right, `#5e5ce6` bottom-left,
  `#ff375f33` mid, base `#111318`), static.
- The only overlay is the ⌘S keycap toast (two keycaps, bottom-right of the
  editor, 560 ms). No cursor, captions, zooms or fades.

## Beats

Times are ms from the `hero.start` bang (= frame 0 of the clip). Keystroke
cadence is a seeded PRNG: 42–76 ms per character plus rests after `>`
(150), `;` (120), `{` (110), `}` (90). Caret blinks only when idle.

| t (ms)      | Left (editor)                                              | Right (widget)                    |
|-------------|------------------------------------------------------------|-----------------------------------|
| 0 – 1200    | Hold. `index.html` tab, 3 lines, caret idle after `</h1>`. | `87%` (live `sd.battery.percent`) |
| 1200        | Enter → line 4. Tab shows the modified dot.                |                                   |
| 1410 – 4148 | Types `<p>{{ sd.battery.cycles }} cycles</p>`               |                                   |
| 4568        | **⌘S** — writes `index.html` (toast until 5128). Dot clears. | ~5100–5300: real reload → second row `41 cycles` |
| 5128 – 6968 | Stillness (≥ 1.7 s after the widget changed).              |                                   |
| 6968        | Click `index.css` tab. 10 lines. Caret idle at end of line 10. |                               |
| 7488        | Caret to line 10, `#f0f0f0` selected (blue selection).     |                                   |
| 7941 – 8286 | Types `#30d158` over the selection (turns green at the 6th digit). |                           |
| 8706        | **⌘S** — writes `index.css` (toast until 9266).            | ~9250–9450: real reload → number turns green |
| 9266 – 12306| Final hold (≈ 2.9 s after the last visible change). Cut to frame 0. |                          |

Eye path per edit: typing (left) → keycap (bottom-right of the editor) →
widget (right). The two sides never move at the same time: after each
save the editor is still until the widget has changed and settled.

## Exact file contents

Frame 1 on disk (`demo/`, generated from `stage/script.js` by `gen.mjs`):

`index.html`
```html
<!doctype html>
<link rel="stylesheet" href="index.css">
<h1>{{ sd.battery.percent }}%</h1>
```

`index.css`
```css
body {
  display: grid;
  place-content: center;
  height: 100vh;
  font: 26px Inter, sans-serif;
  text-align: center;
  color: #a0a0a0;
}
h1, p { margin: 0 }
h1 { font-size: 84px; color: #f0f0f0 }
```

Save 1 (t = 4568) writes `index.html` =
```html
<!doctype html>
<link rel="stylesheet" href="index.css">
<h1>{{ sd.battery.percent }}%</h1>
<p>{{ sd.battery.cycles }} cycles</p>
```

Save 2 (t = 8706) writes `index.css` with line 10 changed to
```css
h1 { font-size: 84px; color: #30d158 }
```

Every file is `lines.join("\n") + "\n"` of the editor buffer at that beat —
`stage/script.js` is the single source for both the editor and `gen.mjs`;
`node gen.mjs check` verifies `demo/` against it and `record.sh` verifies
the on-disk files after the take.

## Why two helper daemons (read before phase 2)

stackd's hot reload is global: `FileWatcher` → `StackHost.reloadAll()`
unloads and re-spawns *every* stack in the daemon (`Sources/AppDelegate.swift`,
`Sources/StackHost.swift`). If the stage and the widget lived in the same
daemon, every save would also tear the stage down and the real desktop
would show through for ~200–400 ms — a privacy leak and a visible glitch.

`record.sh` therefore launches two throwaway stackd instances via launchd,
each with its own `HOME` under `/tmp/stackd-hero-<time>/` (own `~/stackd`
root, own IPC socket — the path has to be short because `sockaddr_un` caps
socket paths at 104 bytes), from the same signed `/Applications/stackd.app`
binary:

- `stackd.hero.stage` hosts `hero-stage` (level 960, fullscreen) and
  receives `stackd bang hero.start dir=<demo folder>`.
- `stackd.hero.demo` hosts `hero-demo` (level 1000 "tooltip"); its own
  FSEvents watcher reloads the widget when the stage writes into it.

The user's daemon and `~/stackd/` are never touched; `record.sh` records
`stackd list` before and after and warns on any difference.

## Debug / look-dev

- `stage/index.html?beat=N` (1–7) or `?t=<ms>` freezes the timeline at a
  state; add `&mock=1` in headless Chrome to draw a stand-in widget
  (translucent fill, not real glass) with the content the demo would show.
- `?play=1&dir=/x` plays in real time (saves are logged, not written,
  outside stackd).
- Live, after the stacks are up: `HOME=<stage-home> stackd bang hero.jump t=4700`
  jumps the real stage (no writes). A jumped stage will not start a take —
  re-run `record.sh` for a fresh pair of daemons.
- Headless render command:
  `"/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary" --headless=new --hide-scrollbars --allow-file-access-from-files --disable-gpu --window-size=1200,676 --force-device-scale-factor=2 --screenshot=out.png "file:///…/stage/index.html?beat=3&mock=1"`
  (`--allow-file-access-from-files` is required for the ES module import
  over `file://`).
