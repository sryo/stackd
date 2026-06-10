# AGENTS.md — start here

A 30-line pointer for any agent landing in this repo. The authority is [CLAUDE.md](CLAUDE.md); this file is the "if you only read one thing" version.

## Build & verify (the contract)
- `./build.sh` → `.build/stackd` (production binary).
- `./tests.sh` → `.build/stackd-tests` (derives sources from `build.sh`; the two cannot drift).
- Daemon ownership: rebuild, launch, kill, reload — you own it. Use `/stackd-rebuild-restart` (or `scripts/daemonctl.sh`) instead of ad-hoc `pkill stackd`.

## The four locked rules (see CLAUDE.md → Architecture)
1. **Hammerspoon is the inspiration — and the project stackd aims to replace.** `hs.<x>` names/coverage are the bar (parity or better, never worse); call semantics go web-native where the async bridge demands (Promises, batch-first). HS is a reference to consult, never a runtime dependency.
2. **WebKit is the only rendering surface** — click-through `NSPanel` + `WKWebView`; no `CGContext` DSLs, no SVG path strings, no native canvas.
3. **Primaries in respective sources** — window things in `Windows.swift`, AX walks for window properties in `Windows.swift`, not in callers.
4. **Observe and set, nothing else** — daemon doesn't render, decide, diff, latch, or curate. Stacks do.

## Same-commit doctrine (non-negotiable)
- New `sd.X` primitive → same commit ships: `Sources/DataSources/<X>.swift`, `Sources/Bridge.swift` registration, `Sources/Channels.swift` entry, `Sources/Permissions.swift` entry, `Runtime/api.js` namespace, `build.sh` if new sources/frameworks, **and a test** in `Tests/`.
- New channel → one `Channel(...)` entry in `Sources/Channels.swift`; that's the single source of truth for both `Bridge.replayState()` and the JS `__sdSignalPaths` lookup.
- Use the `tdd` skill's red-green-refactor loop. Tests written after the fact pin down the *shape* of the implementation, not the behavior.

## Pre-commit checks (in this order)
1. `/stackd-channel-check <permission>` — runs the `channel-registry-auditor` on one permission. Catches drift before CI.
2. `./tests.sh` — full suite, or `.build/stackd-tests --filter <regex>` for a focused subset.
3. `docs/sync.py --check` — verifies `<!-- include: ... -->` blocks still match their source files (already wired into `tests.sh`).

## Stack locations (this trips up new agents)
- `examples/` → demo/test scaffolding (in repo).
- `~/stackd/stacks/` → the user's day-to-day stacks (NOT in repo).
- Cross-stack changes touch BOTH if both have the stack.

## Don't do this
- Don't add backwards-compatibility shims; just change the code.
- Don't add `NSApp.activate` anywhere — `.accessory` policy + `.nonactivatingPanel` mask are load-bearing.
- Don't use CSS `backdrop-filter` in stack HTML — daemon owns chrome via manifest `material:`.
- Don't trust SourceKit cross-file errors; only `./build.sh` non-zero exit signals a real error.
- Don't poll where an event source exists (`AudioObjectAddPropertyListenerBlock`, `NotificationCenter`, FSEvents, AX observers, `CGEventTap`, kqueue). And **verify the listener actually fires** before trusting it (CoreAudio silently no-ops some registrations).
