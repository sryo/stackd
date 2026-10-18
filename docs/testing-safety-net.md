# Refactor safety net

What has to hold before, during and after a large refactor so that no feature
is lost. Six layers, cheapest first. L1–L4 and L6 are headless and run
anywhere; L5 drives the live desktop and needs the owner's agreed time window.

| layer | what it proves | how | cost |
|---|---|---|---|
| L1 public surface | nothing a stack, the CLI or the bench can observe was dropped or renamed | golden snapshot test | in `./tests.sh` |
| L2 regression ledger | where a refactor can bring back an already-fixed bug unnoticed | `scripts/regression-ledger.py` → `docs/regression-ledger.md` | seconds |
| L3 stack compatibility | every example and every installed stack still loads, gets the same permissions and only calls members that exist | test over `examples/` (golden) and `~/stackd/stacks` (read-only) | in `./tests.sh` |
| L4 record/replay | window-server bursts replay through the intake | design only (see below) | — |
| L5 live gates | the window/overlay/input behavior a user feels is unchanged | `stackd doctor`, bench A/B, `qa-windowscape.sh`, owner pass | 30–45 min of screen time |
| L6 mutation check | the tests still catch the bugs they were written for | `scripts/mutation-check.sh` | ~80 s per mutation |

## Commands

```sh
./tests.sh                                              # everything below runs in here
./tests.sh --filter '^surface:|^stack compat:'          # just L1 + L3
STACKD_UPDATE_GOLDEN=1 ./tests.sh --filter '^surface:|^stack compat:'   # accept an intentional change
STACKD_COMPAT_BASELINE=<file> ./tests.sh --filter '^stack compat:'      # user stacks vs a saved report
scripts/regression-ledger.py --out docs/regression-ledger.md            # L2 report
scripts/mutation-check.sh --list                        # L6 candidates
scripts/mutation-check.sh [sha ...]                     # L6 run
```

After a golden failure the actual output is in `.build/golden/`, so
`diff -u Tests/Golden/public-surface.txt .build/golden/public-surface.txt`
shows the whole change. The test message already lists it per section.

## L1 — public surface contract

`Tests/PublicSurfaceTests.swift` renders `Tests/Golden/public-surface.txt`
and compares. Sections:

| section | source | catches |
|---|---|---|
| `[permissions]` | `Permissions.all`, `inferable` | a dropped permission (every stack declaring it gets a doctor warning, inference stops granting it) |
| `[channels]` | `Channels.all`, in order | a channel dropped, renamed, re-gated, turned delta, or replayed in a different order |
| `[primitives]` | `Bridge.primitiveContract` | a wire type dropped or renamed, a permission gate changed, a different denial value (`false` vs `null` vs `[]`) |
| `[runtime]` | `window.sd` walked in JavaScriptCore via `JSHarness` | an `sd.*` member dropped, a signal turned into a function, a function's arity changed |
| `[runtime.globals]` | `__sd_*` / `onBang_*` functions the runtime installs | a daemon→page callback renamed on one side |
| `[overlay.page]`, `[page.events]` | source scan | `sd.target`, `sd:target`, `sd:screen`, `stackd:frame` |
| `[manifest]` | a sample `stack.json` setting every key, decoded and reflected | a manifest key renamed or dropped (its value turns `nil`) |
| `[cli]` | `CLI.helpText` | a verb dropped from `stackd help` |
| `[bangs]`, `[env]`, `[templates]` | source scan | a bang name, a `STACKD_*` switch (the bench depends on `STACKD_WIN_DEBUG` / `STACKD_CGS_DEBUG`), a template directive |

Four cross-checks hold regardless of the golden:

- every wire type `Runtime/src` sends is a bridge primitive (none silently dropped by `Bridge.dispatch`);
- every bridge primitive is sent by `Runtime/src` (no dead primitives);
- every `__sd_*` callback the daemon evaluates is installed by the runtime;
- the sample manifest sets every `StackManifest` key (a new key must be added to the sample).

The one production hook is `Bridge.primitiveContract` (type, permission,
denial JSON per primitive), next to the existing `Bridge.primitivePermissions`.

**Doesn't catch:** behavior behind a name (a primitive that still exists but
returns something else), payload shapes of channels and bangs, argument
names inside `sd.*` functions, anything only reachable in a real WKWebView
(DOM template paths), and source-scan sections built in a way the scan can't
see (a bang name assembled at runtime).

**Updating:** an intentional surface change regenerates the golden in the
same commit as the change, and the diff is part of the review:
`STACKD_UPDATE_GOLDEN=1 ./tests.sh --filter '^surface:|^stack compat:'`.

## L2 — regression ledger

`scripts/regression-ledger.py` walks the last 200 commits, keeps the
`fix(`/`fix:`/`revert` ones and marks each by whether it added or changed a
test in the same commit. `scripts/regression-ledger.guards` is the hand-kept
part: fixes guarded since by a later test, or whose code is gone. Everything
else is **unguarded** and ranks by file in `docs/regression-ledger.md`.

At `acff315`: 61 fixes, 52 with a same-commit test, 5 guarded since or
obsolete, 4 unguarded, 1 of them in code (`dc867a5`, signing). The window is
the last 200 commits; `a6098df` (setFrameProbed readback) and `a2f7b15`
(synchronous detach) are older than it now and are still unguarded. Paths
are as of the fix: `Sources/Bridge.swift` fixes may live in
`Sources/BridgeOverlay.swift` now.

The five unguarded areas that pure logic can cover, and the test each needs:

1. **`stackd new` scaffolds** (`6a11d14`, plus `aaa0cd4`/`4ebf931`/`30ac049`
   further back). Written: `Tests/StackTemplatesTests.swift` — every
   template scaffolds a stack that decodes and passes doctor with 0 issues,
   ships no `backdrop-filter`, and only references existing `sd.*` members.
2. **Workspace notification center** (`a142a3e`: the didTerminate observer
   sat on `NotificationCenter.default` and never fired). Written:
   `Tests/WorkspaceNotificationsTests.swift` — a source check that no
   `NSWorkspace.*Notification` is observed on `.default` and no
   `NSApplication.*Notification` on the workspace center. It sees direct
   registrations only, not a center held in a variable.
3. **Hotkey chord sharing** (`bbd6439`: N per-display instances binding one
   chord; `e2f8a73`: `excludeApps`). Not testable through
   `HotkeyRegistry.bind` without registering a live Carbon hotkey, which
   `InputTests` rules out. Written: `Tests/SourceInvariantTests.swift` — a
   source check that `bind` looks up an existing registration of the chord
   before it calls `RegisterEventHotKey`, that every Token it returns
   releases through the reference count, and that only the last release
   calls `unbind(id:)`. It sees the shape of the code, not the behavior;
   the stronger test needs the combo ref-count extracted into a value type
   (`bind(combo) → .register | .share`, `release(combo) → .keep |
   .unregister`) so two binds of one chord register once, the first
   release keeps it, the last unregisters, and a different modifier set is
   a different chord. Same extraction for the app gate: `apps`/`excludeApps`
   compose (both must pass).
4. **Replay payloads are JSON** (`d109864`: a non-JSON `"primed"` marker in
   `lastState` became a ReferenceError on every replay). Written:
   `Tests/SourceInvariantTests.swift` — a source check that every
   `lastState[...] =` write stores a variable or `Bridge.jsonify(...)`
   result, never a literal. The stronger test extracts replay's payload
   selection into a pure function of `(lastState, permissions)` and checks
   that every pushed payload parses with `JSONSerialization`, that a
   channel without a snapshot pushes nothing, and that `windowsChanged`
   pushes nothing before its first real delta.
5. **Never activate stackd** (`52db285`, and CLAUDE.md's "no
   `NSApp.activate` anywhere"; `872c746`: `focus()` needs
   `.activateIgnoringOtherApps` to move another app forward from an
   accessory process). Written: `Tests/SourceInvariantTests.swift` — no
   `NSApp.activate`, `activate(ignoringOtherApps:)` or
   `NSRunningApplication.current.activate` in `Sources/`, the only
   activation policy is `.accessory`, and every `activate(options:)` on
   another app includes `.activateIgnoringOtherApps`.

The remaining unguarded fixes (`a6098df` setFrameProbed readback,
`a2f7b15` synchronous detach, `dc867a5` signing) touch AX, AppKit or
codesign; L5 covers them.

## L3 — stack compatibility

`Tests/StackCompatTests.swift` runs each stack folder through the daemon's
own loader (`StackSource.loadFolder` with the root's `defaults.json`),
`StackDoctor.check`, and `ChannelInference.infer`, then scans the source
(comments removed, quoted bang names skipped) for `sd.a.b` chains and
resolves them against L1's runtime tree. Each stack becomes one line:

```
overlay-border load=ok doctor=1 perms=overlay,settings,spaces,windows ignored=- unresolved=-
```

- `examples/` (one level of grouping, so `bang-pair/*` counts) is pinned by
  `Tests/Golden/stack-compat-examples.txt`, loaded with no `defaults.json`.
- `~/stackd/stacks` (or `$STACKD_COMPAT_ROOT/stacks`) is read-only input.
  Every stack must load and resolve; the report goes to
  `.build/stack-compat/user-stacks.txt`. With
  `STACKD_COMPAT_BASELINE=<saved report>` it must match exactly, which
  pins doctor counts, effective permissions and ignored keys across the
  refactor. Skipped when the folder doesn't exist.

Findings at the time of writing: `examples/click-counter`, `corner-dot` and
`gesture` have no `permissions` key, so they don't load without a
`defaults.json` that supplies one (`StackManifest.permissions` is required);
`examples/README.md` still describes `manifest.hotcorners`, a key nothing
decodes.

**Doesn't catch:** a stack that loads but renders or behaves differently,
`sd.*` calls built dynamically (`sd[name]`), and a string that happens to
read `sd.x.y` (shown as unresolved; the golden pins
`broadcasts-test`'s `sd.test.ping` for that reason).

## L4 — record/replay (design)

What exists is pure and already unit-tested: `CGSWindowEventDecoder.decode`
(payload bytes → event), `IntakeEvent.key`, `IntakeQueue` (merge per kind +
wid), `SpacesCoalescer`, `TraceRing`/`IntakeTracer`/`IntakeTraceDump`. What
blocks an end-to-end replay:

- `STACKD_TRACE` records timing only (`kind`, `t_us`, `queue_us`,
  `handler_us`, `merged`): no event code, wid or payload, so a trace can't
  be replayed.
- The callback's routing (`windowEventsCallback`) is a private closure, and
  `WindowServerIntake.handle` → `WindowEvents.dispatch` returns early
  without `AppDelegate.shared.host`, then fans out to singletons that read
  live AX and AppKit state (`Overlay`, `WindowsAXObserver`,
  `WindowResizeObserver`, `FrontmostWindowObserver`, `host.bang`).
- AX replies aren't funneled through one reader, so they can't be recorded
  without a seam at every `AXUIElementCopyAttributeValue` site.

A replay of the decode + merge stages alone would repeat the existing unit
tests. Two seams make it worth doing, both small and both best added
*before* a window-code refactor, so the refactor is checked against them:

1. **Recorder** (~20 lines): under `STACKD_TRACE=1`, append the raw event to
   the ring at the callback, trace format v2:
   `{"code":806,"words":[1234],"len":16,"t_us":…,"thread":"cgs"}` — the
   same leading-words capture `CGSDecodedWindowEvent.probe` uses. Record a
   fixture once per scenario (drag, retile, space switch, minimize) during
   a bench run; commit them under `Tests/Fixtures/intake/<scenario>.json`.
2. **Sink** (~30 lines): `WindowEvents.dispatch` takes its effects through
   a protocol (`bang(name:detail:)`, `followFrame(wid:)`,
   `noteDestroyed(wid:)`, `reordered(wid:)`, `spaceWindowCreated(wid:)`,
   `frontmostByMouse(pid:)`), with the live implementation as default.

The smallest end-to-end test then: decode every fixture event, offer it to
an `IntakeQueue`, drain in the recorded batch boundaries, dispatch into a
recording sink, and compare the effect list (in order) to a golden next to
the fixture. It pins which bangs fire, in what order, and how a burst
merges, for a real burst. It still can't see AX-driven paths (minimize
confirmation, isStandard probes); L5 owns those.

## L5 — live gates

These drive the real desktop: windows open, move, minimize and take focus,
the cursor moves (`--mouse`), the visible space switches (`--spaces`), and
the daemon and stacks are swapped out while the bench runs. **They run only
inside a time window the owner has agreed to**, announced with the exact
commands and expected duration, and only after the owner says go. Outside
that window an agent prepares everything headlessly and waits.

### Before the window (headless, any time)

1. `BASE=$(git rev-parse --short HEAD)` on the commit before the refactor.
2. `./tests.sh` on `BASE` and on the refactor head: both green; goldens
   unchanged or changed on purpose.
3. User-stack baseline, on `BASE`: `./tests.sh --filter '^stack compat:'`,
   then copy `.build/stack-compat/user-stacks.txt` somewhere outside
   `.build/`. On the head:
   `STACKD_COMPAT_BASELINE=<that file> ./tests.sh --filter '^stack compat:'`.
4. `./build.sh && .build/stackd doctor` on the head: every stack checked,
   SkyLight symbols all present (doctor reads files and `dlsym`s, it doesn't
   start the daemon).
5. `scripts/bench/bench.sh $BASE HEAD --build-only` (from the checkout that
   has `scripts/bench/`): both commits build.
6. `scripts/mutation-check.sh` for the fixes in the files the refactor
   touches (`--list` shows candidates).

### In the window (owner present, hands off)

Preconditions: on AC power, heavy apps closed; no other bench running
(`.build/bench/.lock`, `pgrep -fl bench.sh`) and no other session swapping
the daemon (`pgrep -fl stackd`).

1. **Bench A/B**: `scripts/bench/bench.sh $BASE HEAD --runs 5 --fresh-a`,
   adding `--mouse --spaces` when Input, Windows, Overlay or motion code
   changed (~15–20 min). Gate: no lower-is-better metric worse than the
   noise floor, which is ~10 points for `%` metrics and ~10% for the rest
   (the same code has measured `motion.misframed` 29% and 37% on different
   runs); a delta past it that repeats on a second 5-run is a regression.
   `missed_pct`, `panel_hidden_pct` and `spaces.misplaced_frames` must not
   rise. A `not trusted` warning in the summary voids the run.
2. **Install the head**: `scripts/daemonctl.sh rebuild` (not `start`, which
   runs the packaged app). Then: the log has no `not trusted`, no
   `bad manifest`, no crash backoff; `.build/stackd list` lists every
   folder in `~/stackd/stacks`.
3. **qa-windowscape**: `scripts/qa-windowscape.sh` → 6/6 PASS (exit 0,
   report in `scripts/qa-windowscape/last-run.txt`). It needs windowscape
   and overlay-border loaded, a landscape primary display and the
   TextEdit Automation grant. A failure also seen on `BASE` in the same
   session is environmental; one only on the head is a regression.
4. **Owner pass**: each user stack renders and responds (bars, palette
   hotkey, gestures, overlays). The agent reports what it observed; the
   owner decides whether it's fixed or unchanged.

Any red gate: reinstall `BASE` (`git checkout $BASE && scripts/daemonctl.sh
rebuild`) before the window closes, then debug headlessly.

### Which gate covers which code

| area (Sources/) | tests.sh | L1 | L3 | doctor | bench | qa-windowscape | owner pass / manual |
|---|---|---|---|---|---|---|---|
| `DataSources/Windows.swift`, `WindowMotion.swift`, `WindowResizing.swift`, `BridgeWindows.swift` | ✓ | ✓ | | | motion, retile, drag, resize, focus, raise, minimize, spaces | S1–S6 | |
| `DataSources/WindowServerIntake.swift`, `IntakeTrace.swift` | ✓ | env | | | all scenarios (CGS counts with debug env) | S1–S6 | |
| `DataSources/Overlay.swift`, `BridgeOverlay.swift` | ✓ | ✓ | ✓ | | every `follow_*`, `panel_hidden_pct`, raise, spaces | S5 | overlay-border |
| `Private/SkyLight.swift` | ✓ | | | ✓ | raise, spaces, motion | ✓ | |
| `DataSources/Input.swift`, `BridgeEvents.swift`, `BridgeHotkey.swift` | ✓ | ✓ | | | `--mouse` (live-resize path) | | hotkeys, eventtap consume, trackpad gestures (tttaps, sideswipe) |
| `DataSources/AX.swift`, `BridgeAX.swift`, `DataSources/Apps.swift` | ✓ | ✓ | | | focus | S5 | palette menu search, app focus |
| `Bridge.swift`, `BridgeChannels.swift`, `Channels.swift`, `Permissions.swift`, `Runtime/src/` | ✓ | ✓ | ✓ | ✓ | bench stack (attach, bang, setFrame) | | every stack loads |
| `StackHost.swift`, `StackWindow.swift`, `StackMaterial.swift`, `PassthroughWebView.swift`, `WebViewEval.swift`, `URLSchemeHandler.swift`, `ScreenshotHider.swift` | ✓ | | ✓ | ✓ | | | every stack renders, clicks pass through, screenshots |
| `StackSource.swift`, `StackTemplates.swift`, `CLI.swift`, `IPC.swift` | ✓ | ✓ | ✓ | ✓ | | | `stackd list/reload/bang` |
| `AppDelegate.swift`, `FileWatcher.swift`, `Log.swift` | ✓ | | | | | | daemon starts, hot reload on save, log clean |
| other `DataSources/*` (audio, display, net, sensors, calendar, …) | ✓ | ✓ | ✓ | | | | the matching `examples/*-test` stack |
| `build.sh`, `scripts/daemonctl.sh` | builds | | | | | | AX trust survives `daemonctl rebuild` |

## L6 — mutation check

`scripts/mutation-check.sh` uses real bugs as mutations: each past fix
commit that shipped a test is reverted on top of HEAD (its `Sources/` and
`Runtime/src/` hunks only; today's tests stay) and `./tests.sh` must go red.

- `CAUGHT`: the suite failed, as it should.
- `MISSED`: the suite stayed green; the guarding test was weakened or
  deleted, or the code moved out from under it. Fix the test before the
  refactor.
- `NOBUILD`: the revert no longer compiles against HEAD; inconclusive.
- `SKIP`: the fix no longer reverse-applies.

It needs a clean `Sources/` and `Runtime/src/`, resets them after every
mutation (and on Ctrl-C), and writes logs to `.build/mutation/`. At
`2d6df7b` 18 fixes still reverse-apply. Run the ones in the files a refactor
touches before starting, and once more at the end; a full run is ~25 min.

For files with few revertable fixes, hand-written mutations on the pure
helpers complete the picture: flip a comparison in `OverlayGeometry`,
`MotionPlanner`, `FrameCoalescer` or `IntakeQueue`'s merge key, apply it,
run the focused tests (`.build/stackd-tests --filter '<area>'` after a
build), expect red, revert.

## Residual risk

- Live-only behavior with no headless model: AX timing, WebKit paint
  latency (the bench sees panel frames, not pixels), Carbon hotkeys,
  multitouch, TCC prompts. L5's bench, qa harness and owner pass are the
  only cover, and they sample a few scenarios.
- Payload shapes: L1 pins names, not the JSON a channel pushes or a
  primitive returns. A refactor that renames a payload field passes L1 and
  L3; only stacks (and the owner pass) notice.
- Source-scan sections and the source checks see literal text: code that
  builds a name at runtime, or holds a notification center in a variable,
  is invisible to them.
- `scripts/bench/` isn't committed; it exists only in the owner's main
  checkout, so a worktree can't run L5's bench step.
