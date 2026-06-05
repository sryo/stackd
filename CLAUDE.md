# stackd — agent instructions

## You own the daemon
Rebuild, launch, kill, reload — all yours. `./build.sh` compiles; `.build/stackd` is yours to run directly whenever verification needs it. If a running instance is in the way, kill it and start fresh. Reversal of the previous "never launch" rule on 2026-06-04.

## Architecture (locked rules)
Four interlocking rules — apply them together; any one alone misses the joint:
1. **Hammerspoon is the baseline.** Match `hs.<x>`'s shape unless there's a thesis reason to diverge.
2. **WebKit is the only rendering surface.** No CGContext DSLs, no SVG path strings, no native canvas. The overlay primitive is a click-through NSPanel + WKWebView.
3. **Primaries in respective sources.** Window things in `Windows.swift` even when consumed by `Overlay.swift`. AX walks for window properties land in `Windows.swift`, not the caller.
4. **Observe and set, nothing else.** Rendering, decisions, diffing, latching, curated payloads belong in stacks UNLESS rule 1 says HS does it daemon-side.

Also load-bearing:
- **Daemon ships primitives, stacks compose behaviors.** Before adding `Sources/DataSources/<X>.swift`, ask "could a stack compose this from existing primitives?" If yes, add the missing primitive only — not the policy.
- **Stacks don't poll.** Polling lives in the daemon. `setInterval` in a stack is a missing channel; add the channel and have the stack subscribe.
- **Polling is the last resort, not the default.** When a daemon-side channel needs to push on state changes, look for the event-driven primitive first — `AudioObjectAddPropertyListenerBlock`, `NotificationCenter` / `DistributedNotificationCenter`, FSEvents, AX observers, CGEventTap, kqueue, dispatch sources. Only fall back to a `Timer.scheduledTimer` poll when no event source exists for the property AND record *why* in the observer's doc comment so a future reader knows it was a chosen ceiling, not an unexplored assumption. A low-frequency safety timer alongside listeners is fine — pure polling for state CoreAudio / NSWorkspace / AX could push you on is a bug. **But verify the listener actually fires before trusting it.** Reason for the rule: the audio-processes bar tried per-process `kAudioProcessPropertyIsRunningOutput` listeners (2026-06-05) — `AudioObjectAddPropertyListenerBlock` *accepted* the registration silently but never invoked the block. CoreAudio documents that property as queryable; observability isn't guaranteed in practice. Outcome: list-listener (which does fire) for add/remove + 1s poll for the IsRunningOutput flip the listener can't see.
- **Never frontmost.** `.accessory` activation policy + `.nonactivatingPanel` style mask are load-bearing. No `NSApp.activate` calls anywhere.
- **Daemon owns chrome.** Material/blur via manifest `material:` (`glass` / `vibrancy.<name>` / `glass.tinted(#RRGGBB)`); stack HTML must NOT use CSS `backdrop-filter` or `-webkit-backdrop-filter`. `NSWindow.hasShadow = false` on glass is intentional — the user finds the shadow ugly.
- **Auto-padding contract.** Glass stacks with `cornerRadius > 0` and no explicit `padding:` get `body { padding: cornerRadius/2 }` injected last-cascade-wins. Full-bleed content (SVG, canvas) needs `"padding": 0` in the manifest — not in CSS, which loses the cascade.
- **HS is the oracle for window/AX bugs.** Diverge from HS → stackd regression. `hs -c "..."` first; name BOTH the HS path AND the stackd path when claiming parity.

## Test every new daemon-side behavior
Every new sd.* primitive, template-engine feature, parser/frontmatter change, manifest field, channel inference rule, or any other daemon-side behavior MUST ship with at least one test in the SAME commit. No "I'll add tests later" deferrals.

**Why:** TDD was adopted on 2026-06-01. Tests written after the fact pin down the *shape* of the implementation rather than the actual behavior — the TDD skill calls this the "horizontal slicing" anti-pattern. Same-commit tests stay honest about what changed.

**How:**
- Use the red-green-refactor loop (see the `tdd` skill): one test fails → write minimal code to pass → repeat. Not "write all tests then all code."
- The harness lives at `Tests/Harness.swift`. Run via `./tests.sh` (parallels `./build.sh` as the verification contract).
- Wire each new `Tests/<Unit>Tests.swift` into `Tests/main.swift` (`register<Unit>Tests()`) and add it to the `TEST_SOURCES` array in `tests.sh`.
- Test through public interfaces, not private helpers. Do NOT change visibility of production code just to make it testable — design for testability instead.
- For impure primitives (anything touching macOS state, AppKit, files): test whatever can be tested in isolation (argument parsing, manifest validation, pure helpers). The TDD skill is explicit: you can't test everything — focus on critical paths.

**Mirrors the "doctor allowlist" pattern:** add the test in the SAME commit as the feature, not later. Same-commit tests stay honest; later-added tests test the implementation, not the behavior.

## Doctor allowlist — same-commit rule
When shipping a new `sd.X` primitive, the same commit MUST add `"X"` to `Permissions.all` in `Sources/Permissions.swift` (the canonical permission registry). Both `StackDoctor.known` and `ChannelInference.topLevelChannels` derive from `Permissions.all` after the A2 refactor — one edit, both consumers update. `PermissionsRegistryTests` cross-validates `Bridge.primitivePermissions` against the registry, so a primitive that declares `permission: "foo"` without "foo" in `Permissions.all` fails CI before the commit lands. Composite permissions (like `menubar.item`, with stricter side-effects than the base namespace) go in `Permissions.all` but stay out of `Permissions.inferable` so they require explicit manifest opt-in. The feature commit's staged set must include: new `Sources/DataSources/<Foo>.swift`, the `Sources/Bridge.swift` registration, `Sources/Channels.swift` (the channel registry — drives both `replayState()` and the JS template engine's `__sdSignalPaths`; see "Channel registry" below), `Sources/Permissions.swift` (the canonical permission registry), `Runtime/api.js` (the `sd.X` namespace), `build.sh` if new sources/frameworks, and the test.

## Channel registry — single source of truth
`Sources/Channels.swift` owns the canonical `Channel { name, jsPath, permission, replayable }` list (`Channels.all`). Both sides of the bridge derive from it:
- Swift: `Bridge.replayState()` iterates `Channels.all`, filters by permission, pushes `lastState[ch.name]` for each replayable entry.
- JS: `window.__sd_channels` (injected at `.atDocumentStart` from `Channels.jsBootstrapJSON`) becomes the template engine's `__sdSignalPaths` lookup at module load — so `{{ sd.<jsPath>.x }}` placeholders auto-subscribe.

Adding a new channel = one `Channel(...)` entry in `Channels.swift`. The same-commit guard is `Tests/ChannelsRegistryTests.swift`, which snapshots the expected replayable set and jsPath set — drift fails CI before it hits a stack. Pure delta channels (no `lastState` snapshot) pass `replayable: false`; channels with no template surface pass `jsPath: nil`.

## Build & test
- `./build.sh` — production build (`.build/stackd`). Verification contract.
- `./tests.sh` — test build + run (`.build/stackd-tests`). Derives source list from `build.sh` automatically so the two can't drift.
- **SourceKit false positives:** Per-file SourceKit analysis can't see whole-module symbol resolution from the one-shot `swiftc` invocation in build.sh. Inter-file "Cannot find type X" errors on `Bridge.swift` / `StackHost.swift` / `Display.swift` etc. are diagnostic noise; only `./build.sh` non-zero exit signals a real error.

## Stack locations
The user's installed stacks live at `~/stackd/stacks/`, NOT just `examples/` in the repo. `examples/` is demo/test scaffolding; `~/stackd/stacks/` is day-to-day. When asked about "all stacks" or making any cross-stack style/manifest change, touch BOTH if both have the stack.

## JavaScript runtime (Runtime/api.js)
The `{{ }}` / `sd-each` / `sd-if` template engine lives in `Runtime/api.js`, not Swift. `Tests/JSHarness.swift` loads it into a `JavaScriptCore` JSContext with a minimal `window` + `document` + `setTimeout` shim. Use it for pure-logic tests of the `__sd*` internal functions: `__sdScanPlaceholders`, `__sdCompilePlaceholder`, `__sdEvalWithScope`, etc. — see `Tests/TemplateEngineTests.swift` for examples.

**DOM-coupled paths NOT tested here**: `__sdProcessTextNode`, `__sdProcessAttribute`, `__sdProcessEachElement`, `__sdSetupIfElement`, `__sdCompileTemplates` all mutate real DOM nodes. Testing those needs a WKWebView harness (async, semaphore-bridged) — open work item.

## Lineage
Kept here (gitignored) rather than in the public README. Useful when naming new primitives or matching existing patterns — knowing the heritage tells you the convention.

`hs.canvas` and `hs.drawing` from Hammerspoon. `--item` and `--message` from SketchyBar. `stacks` from HyperCard. `bangs` from LiteStep. `signals` from Solid/Preact. `defaults.json` from SketchyBar's `--default`. The private SPI vendoring pattern (DisplayServices, MediaRemote, SkyLight, MultitouchSupport) from every macOS power-user tool that ever wanted to do something Apple didn't bless.
