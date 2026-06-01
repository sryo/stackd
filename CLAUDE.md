# stackd — agent instructions

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

## Build & test

- `./build.sh` — production build (`.build/stackd`). Verification contract.
- `./tests.sh` — test build + run (`.build/stackd-tests`). Derives source list from `build.sh` automatically so the two can't drift.
- Never launch `.build/stackd` directly — it conflicts with the user's running daemon instance. Build success = verification success.

## JavaScript runtime (Runtime/api.js)

The `{{ }}` / `sd-each` / `sd-if` template engine lives in `Runtime/api.js`, not Swift. `Tests/JSHarness.swift` loads it into a `JavaScriptCore` JSContext with a minimal `window` + `document` + `setTimeout` shim. Use it for pure-logic tests of the `__sd*` internal functions: `__sdScanPlaceholders`, `__sdCompilePlaceholder`, `__sdEvalWithScope`, etc. — see `Tests/TemplateEngineTests.swift` for examples.

**DOM-coupled paths NOT tested here**: `__sdProcessTextNode`, `__sdProcessAttribute`, `__sdProcessEachElement`, `__sdSetupIfElement`, `__sdCompileTemplates` all mutate real DOM nodes. Testing those needs a WKWebView harness (async, semaphore-bridged) — open work item.
