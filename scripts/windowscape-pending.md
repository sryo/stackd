# PENDING: windowscape pairwise-resize + lifecycle hunks (apply then delete this file)

## RECOVERY ORDER (when shell/write access returns)

The running daemon is still the OLD binary and the installed stacks are OLD code, so
the red baseline is still capturable. Do it FIRST:

1. `chmod +x scripts/qa-windowscape.sh && bash -n scripts/qa-windowscape.sh`, smoke-test
   the JXA oracle (`osascript -l JavaScript scripts/qa-windowscape/cgwindows.js landscape`
   → `true`; `... cgwindows.js checkI2 '{"excluded":"com.apple.loginwindow"}'` → `OK n=...`
   or a FAIL line, never a JS exception), then run `scripts/qa-windowscape.sh` → RED
   baseline (~1-3 min; opens up to 6 TextEdit windows titled qa-ws-N.txt + Calculator,
   cleans up on exit; FAIL lines are expected; one "control TextEdit" TCC dialog on
   first run — Allow). Harness rework 2026-06-09: pure JXA/CGWindowList oracle +
   AppleScript-on-TextEdit driver; `scripts/qa-windowscape/oracle.lua` is unused — delete it.
2. Apply the hunks below to ~/stackd/stacks/windowscape/.
3. `cp examples/overlay-border/index.html ~/stackd/stacks/overlay-border/index.html`
4. `./build.sh && ./tests.sh` (daemon lifecycle rework + overlay repin tests, never run)
5. `scripts/daemonctl.sh rebuild` (or restart), with STACKD_WIN_DEBUG=1 for the log lines.
6. Re-run `scripts/qa-windowscape.sh` → compare against baseline; then the live
   checklists (bottom of this file + agents' reports + Tests/OverlayTests).

Status artifact from the 2026-06-09 bug round. The sandbox classifier outage blocked
all writes to ~/stackd/stacks/windowscape/; these are the fully-specified hunks the
windowscape agent verified against the live file contents. Apply in order, then run
the live-verification checklist at the bottom, then DELETE this file.

Also pending from the same outage (other tasks):
- `cp examples/overlay-border/index.html ~/stackd/stacks/overlay-border/index.html`
- `./build.sh && ./tests.sh` (daemon lifecycle rework + overlay repin, unverified)

## 1. stack.json line 9 — resized bangs are DROPPED today (root cause)

`handles` lacks `"sd.window.resized"`. StackHost.bang() (Sources/StackHost.swift:299)
fans out only to bridges where bridge.handles(bang:) is true (set from manifest
`handles`, Bridge.swift:416); windowscape assigns `window.onBang_*` directly and never
uses sd.bang.declare().on(), so nothing else registers it. Append to the array:

```json
  "handles": ["sd.window.created", "sd.window.destroyed", "sd.window.titleChanged", "sd.window.minimized", "sd.window.deminimized", "sd.window.moved", "sd.window.resized"],
```

## 2. events.js — replace `pinFromActualSize` (lines 439–471) entirely

```js
// User resize → edge-aware PAIRWISE transfer: pin BOTH sides of the
// dragged edge. The resized window A keeps its actual major-axis size; the
// neighbor across the dragged edge (B) gives/takes exactly the delta. A+B's
// combined px nets to zero change, so the flex remainder — and every other
// tile's share — stays exactly where it was. (The previous model pinned
// only A and let ALL flex siblings absorb the delta proportionally.)
//
// Edge picking: if A's major-axis origin moved >5px off its tile target,
// the LEADING edge was dragged → B is the previous non-collapsed tile in
// display order; otherwise the TRAILING edge → next tile. A missing
// neighbor (A at the row end) falls back to the other side; a solo tile
// stays unpinned.
export function pinFromActualSize(movedId) {
  const w = state.windowsById[movedId];
  if (!w || !w.frame) return;
  const d = displayForWindow(w);
  if (!d) return;
  const tiled = state.lastTiledByDisplay[d.displayID];
  if (!tiled || tiled.length === 0) return;
  const onScreen = tiled.filter((id) => {
    const ww = state.windowsById[id];
    return ww && ww.frame && ww.frame.h > cfg.collapsedWindowHeight;
  });
  if (onScreen.length < 2) return; // single tile: pin meaningless
  const idx = onScreen.indexOf(+movedId);
  if (idx < 0) return;

  const horizontal = d.frame.w > d.frame.h;
  const tgt = state.lastTileTarget?.[+movedId]?.frame;
  if (!tgt) return;
  const actualSize = horizontal ? w.frame.w : w.frame.h;
  // A's baseline: its pin when already pinned (the pin IS its target),
  // else its last tile target.
  const aBase = state.pinnedSizes[+movedId] ?? (horizontal ? tgt.w : tgt.h);
  const delta = actualSize - aBase;
  if (Math.abs(delta) < 20) return;

  // Which edge moved? Origin drift on the major axis = leading-edge drag.
  const originDrift = Math.abs(horizontal ? w.frame.x - tgt.x : w.frame.y - tgt.y);
  const leading = originDrift > 5;
  let bIdx = leading ? idx - 1 : idx + 1;
  if (bIdx < 0 || bIdx >= onScreen.length) bIdx = leading ? idx + 1 : idx - 1;
  const bId = onScreen[bIdx]; // exists: onScreen.length >= 2

  state.pinnedSizes[+movedId] = Math.max(50, Math.floor(actualSize));

  // B's baseline: its pin if pinned, else its last tile target, else live frame.
  const bTgt = state.lastTileTarget?.[+bId]?.frame;
  const bLive = state.windowsById[bId]?.frame;
  const bBase = state.pinnedSizes[+bId]
    ?? (bTgt ? (horizontal ? bTgt.w : bTgt.h) : null)
    ?? (bLive ? (horizontal ? bLive.w : bLive.h) : null);
  if (bBase == null) {
    log(`PIN-PAIR id=${movedId} neighbor ${bId} has no target/frame — pinned A only`);
    if (state.onLayoutChange) state.onLayoutChange();
    return;
  }
  const bWant = Math.floor(bBase - delta);
  if (bWant < 50) {
    // Clamp; do NOT push the overflow to a third tile — accepted imperfection.
    log(`PIN-PAIR clamp neighbor ${bId} ${bWant}px → 50px (overflow not redistributed)`);
  }
  state.pinnedSizes[+bId] = Math.max(50, bWant);
  if (state.onLayoutChange) state.onLayoutChange();
  log(`PIN-PAIR ${horizontal ? "w" : "h"} edge=${leading ? "leading" : "trailing"} A=${movedId}→${state.pinnedSizes[+movedId]}px B=${bId}→${state.pinnedSizes[+bId]}px delta=${Math.round(delta)}`);
}
```

## 3. events.js — created-bang seeding (replace lines 266–268)

```js
  window.onBang_sd_window_created = (detail) => {
    // Seed the live index from the bang payload (daemon rework 2026-06:
    // created bangs carry {id, pid, app, title, frame}). The daemon tries
    // to land the sd.windows.all push BEFORE this bang, but on retry
    // exhaustion the bang can still win the race — seeding here makes
    // handleWindowEvent's diff see the window either way.
    if (detail && detail.id != null && detail.frame) {
      const id = +detail.id;
      destroyedRecently.delete(id);
      const w = state.windowsById[id] || (state.windowsById[id] = { id });
      w.pid   = detail.pid;
      w.app   = detail.app;
      w.title = detail.title;
      w.frame = detail.frame;
    }
    debouncedHandleWindowEvent();
  };
```

## 4. events.js — split moved/resized + out-of-bracket path

Rename `const handleDragEnd = (detail) => {` (line 309) to
`const handleDragBang = (detail, kind) => {`; replace lines 376–377 with:

```js
  window.onBang_sd_window_moved   = (detail) => handleDragBang(detail, "moved");
  window.onBang_sd_window_resized = (detail) => handleDragBang(detail, "resized");
```

Replace the out-of-bracket tail (lines 372–374, the `DRAG-ACCEPTED-OUTSIDE-BRACKET`
log + comment) with:

```js
    // Outside any bracket → app/script/AX-driven change.
    if (kind !== "resized") {
      // moved-only: ignore. The next tile pass snaps positions back, and
      // reacting to every AX move would fight app-internal moves.
      log(`MOVE-IGNORED-OUTSIDE-BRACKET id=${detail.id} (${app})`);
      return;
    }
    // WHY the tilingCount gate: our own PASS-1/PASS-2 setFrame calls bounce
    // back as resized bangs. The echo guard above only catches ≤5px matches
    // against the FINAL target — intermediate/refused frames miss it, and
    // reacting would pin + retile + bang again, forever. tilingCount spans
    // the whole pass plus its 150ms cooldown.
    if (state.tilingCount > 0) {
      log(`RESIZE-IGNORED-TILING id=${detail.id} (${app})`);
      return;
    }
    const wd = displayForWindow(w);
    if (!wd || !tgt || !tgt.frame || !detail.frame) return;
    const horizontal = wd.frame.w > wd.frame.h;
    const dMajor = Math.abs(horizontal
      ? detail.frame.w - tgt.frame.w
      : detail.frame.h - tgt.frame.h);
    if (dMajor <= 20) return;
    log(`RESIZE-OOB-BANG id=${detail.id} (${app}) dMajor=${Math.round(dMajor)} → debounce`);
    scheduleOutOfBracketResize(+detail.id);
  };
```

## 5. events.js — add module-level debounce (after handleWindowEvent, before `export function start()`)

```js
// Out-of-bracket resize debounce — replaces the removed 500ms drift-watch
// poll. The daemon's per-window AX observers bang on every app/script-
// driven resize now; we debounce 300ms (same shape as lua's
// pendingReposition timer) so the last bang of a resize train wins, then
// run the SAME pairwise pin + retile as a bracket-close resize.
let oobResizeTimer = null;
let oobResizeId = null;
function scheduleOutOfBracketResize(id) {
  oobResizeId = id;
  if (oobResizeTimer) clearTimeout(oobResizeTimer);
  oobResizeTimer = setTimeout(async () => {
    oobResizeTimer = null;
    const movedId = oobResizeId;
    oobResizeId = null;
    if (movedId == null) return;
    // A real user drag opened meanwhile — bracket close owns the decision.
    if (state.dragInFlight) return;
    log(`RESIZE-OUTSIDE-BRACKET id=${movedId} → pairwise pin + tile`);
    pinFromActualSize(movedId);
    state.tileReason = `ax-resize(${movedId})`;
    await tileWindows();
  }, 300);
}
```

Also update the comment block at events.js lines 292–308: out-of-bracket resized →
debounced pairwise pin; moved-only → ignored; "synth poll" references → per-window
AX observers.

## 6. tiler.js — delete lines 243–287

Remove `driftWatcherTimer`, `driftPaused`, `driftWatch`, `startDriftWatcher`,
`pauseDriftWatcher` + header comment. Fix line 187–188 comment: "so drift-watch /
echo-suppression see" → "so echo-suppression sees"; line 191 "what makes drift go
quiet" → "what keeps echo-suppression current".

## 7. main.js

Line 7: `import { tileWindows, startDriftWatcher }` → `import { tileWindows }`;
delete line 21 `startDriftWatcher();`.

## 8. core.js lines 13–15 — pinnedSizes comment

Replace "Written by user-drag (events.js pinFromActualSize), drift watcher, AX
refusal (tiler.js PASS-2), and grow/shrink/cycleWidth verbs." with "Written by
user-resize pairwise transfer (events.js pinFromActualSize — pins both sides of the
dragged edge), AX refusal (tiler.js PASS-2), and grow/shrink verbs."

Cross-checks already done by the authoring agent: startDriftWatcher/pauseDriftWatcher/
driftWatch appear ONLY in tiler.js and main.js; pruneStaleWeights already cleans
pinnedSizes (covers new B-pins); solo-tile pin-drop (tiler.js:126–128) untouched;
cfg.eventDebounceSeconds = 0.03s left as is.

## Live-verification checklist (after apply + daemon rebuild)

- Drag A/B shared edge (right edge of A) → ONLY A and B change; log
  `PIN-PAIR w edge=trailing ...`; third window pixel-identical.
- Drag A's leading (left) edge → B is the PREVIOUS tile; `edge=leading`.
- A at row end → fallback neighbor, no crash.
- Huge A grow → `PIN-PAIR clamp`, B at 50px, no third-window spill.
- Script resize (hs/osascript, no mouse) → `RESIZE-OOB-BANG` then
  `RESIZE-OUTSIDE-BRACKET` ~300ms later (needs hunk 1 or nothing fires).
- Script MOVE only → `MOVE-IGNORED-OUTSIDE-BRACKET`, no retile.
- No `RESIZE-OUTSIDE-BRACKET` storm during tile passes (`RESIZE-IGNORED-TILING`
  / `DRAG-IGNORED echo` instead); tile-pass count settles.
- `open -na Terminal` → tiled on first pass (created-bang seeding).
- Zero `DRIFT-WATCH` logs, no 500ms wakeups.
- ctrl+cmd+0 clears pins; solo-tile pin-drop still fires.
