# What stackd believes

Nine principles. Each one names something the daemon already does, or refuses to do.

## 1. Data is live, or it isn't data.

A stack asks for `{{ sd.battery.percent }}` and gets the current value. The daemon polls, hashes, dedupes, and pushes; the stack only subscribes.

## 2. The folder is the program.

Drop a folder into `~/stackd/stacks/`, it runs. No build, no registry, no single-file archive pretending to be tidier — and deleting the folder drains every observer and hotkey it held.

## 3. Primitives, not products.

Every `sd.*` API is a general primitive with at least two unrelated callers. No `sd.spotify` — there's `sd.media`, and Spotify is one feed of many.

## 4. Native trusts. HTML shows.

The native layer owns Accessibility, eventtaps, IOKit, permissions, observation. The web layer owns pixels; the bridge between them is sharp on purpose.

## 5. Scopes drain. Nothing leaks.

Every native resource a stack acquires returns a token, and the token lives in a `StackScope`. Unload drains the scope in reverse order, and a stack that crashes leaves nothing behind.

## 6. Reads inferred. Writes declared.

Permissions for read-only signals are auto-inferred from `sd.<channel>` references in your code. RPC actions that change the world stay explicit in the manifest — reading and writing aren't the same thing.

## 7. Tests ship with behavior.

A new primitive, a new manifest field, a new template-engine feature — each lands in the same commit as the test that pins it. Tests written later test the implementation; tests written alongside test the thing.

## 8. Never frontmost.

stackd lives on your desktop, not in your way. Panels are non-activating; the daemon never calls `NSApp.activate`.

## 9. Idle stacks cost nothing.

An observer with no subscribers stops polling after a few seconds. A stack you unload releases every hotkey, eventtap, and AX subscription it held — nothing keeps running because it once did.
