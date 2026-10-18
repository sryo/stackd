# AGENTS.md — start here

A pointer for any agent landing in this repo. The authority is [CLAUDE.md](CLAUDE.md); read it before changing anything.

## Build and verify
- `./build.sh` builds the daemon.
- `./tests.sh` builds and runs the whole suite; `./tests.sh --filter <regex>` runs a subset by test name. Exit status: 0 passed, 1 failures, 2 usage error (bad pattern, no test matched, duplicate test name).
- Both scripts glob the Swift sources, so a new file needs no list edit.
- `Runtime/api.js` is generated from `Runtime/src/` and gitignored: edit `Runtime/src/*.js`, never `api.js`.
- The daemon is yours to rebuild, kill and relaunch; `scripts/daemonctl.sh rebuild` does it safely.

## The four locked rules
1. Hammerspoon is the reference and the project stackd aims to replace: match `hs.<x>` names and coverage, go web-native (Promises, batch-first) where the async bridge demands it, and never depend on HS at runtime.
2. WebKit is the only rendering surface: a click-through `NSPanel` + `WKWebView`, no `CGContext` drawing, no native canvas.
3. Primaries live in their respective sources: window and AX-window things in `Windows.swift`, even when another file consumes them.
4. Observe and set, nothing else: rendering, decisions, diffing and latching belong in stacks.

## Before you commit
- Every new daemon-side behavior ships with a test in the same commit.
- A new `sd.X` primitive also ships its `Sources/Permissions.swift`, `Sources/Channels.swift`, `Sources/Bridge.swift` and `Runtime/src` entries; CLAUDE.md lists the full set.
- `./tests.sh` passes, and so does `docs/sync.py --check` (`tests.sh` runs it).
- Never add `NSApp.activate`, and never use CSS `backdrop-filter` in stack HTML.

The user's day-to-day stacks live in `~/stackd/stacks/`, outside this repo; `examples/` is the in-repo reference set. A cross-stack change touches both when both have the stack.
