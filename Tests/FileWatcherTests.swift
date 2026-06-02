import Foundation

// FileWatcher is almost entirely impure: it wraps FSEventStreamCreate
// against real paths, fires a C callback on the main dispatch queue, and
// debounces with DispatchQueue.main.asyncAfter. None of that is testable
// without (a) real filesystem events on a real watched directory or
// (b) reaching into a private static Set inside a C-trampoline closure.
//
// The one piece of *policy* worth characterizing is the reload-extension
// allowlist (FileWatcher.reloadExtensions) — the regression it exists to
// prevent (digup.db-wal: 17 spurious reloads per idle session, see the
// source comment) is exactly the kind of thing that would silently regress
// if someone "helpfully" added "db" or "wal" or "log" to the set.
//
// The set itself is `private static`, and the path predicate
// (`reloadExtensions.contains((path as NSString).pathExtension.lowercased())`)
// lives inside an FSEventStreamCallback C trampoline with no public exit.
// So these tests are *witness* tests: they replicate the exact predicate
// the production callback applies, mirror the allowlist as documented in
// source, and assert on the contract. If someone changes the allowlist in
// FileWatcher.swift without updating this mirror, the production behavior
// drifts silently — but the test fixture below makes the intended set
// explicit, which is the best we can do without changing visibility.

private let expectedReloadExtensions: Set<String> = [
    "js", "mjs", "html", "htm", "css", "json", "svg", "wasm"
]

// Mirror of the production predicate (FileWatcher.swift line 38-39).
// If this diverges from the source, the witness tests stop being a
// faithful characterization — keep them in sync by hand.
private func shouldReload(path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return expectedReloadExtensions.contains(ext)
}

func registerFileWatcherTests() {
    test("witness: reload allowlist contains the stack-source extensions") {
        // Stack authors write these; edits must trigger reload.
        for ext in ["js", "mjs", "html", "htm", "css", "json", "svg", "wasm"] {
            try expect(expectedReloadExtensions.contains(ext), "expected \(ext) in allowlist")
        }
    }

    test("witness: reload allowlist excludes sqlite/wal/plist/pid/lock/log runtime extensions") {
        // The digup.db-wal regression (see FileWatcher.swift source comment):
        // runtime data files written by stacks must NOT cycle the host.
        for ext in ["db", "sqlite", "sqlite-wal", "wal", "shm", "plist", "pid", "lock", "log"] {
            try expect(!expectedReloadExtensions.contains(ext), "\(ext) must NOT be in allowlist")
        }
    }

    test("predicate accepts stack-source files regardless of case") {
        try expect(shouldReload(path: "/x/y/index.html"))
        try expect(shouldReload(path: "/x/y/INDEX.HTML"))
        try expect(shouldReload(path: "/x/y/style.CSS"))
        try expect(shouldReload(path: "/x/y/manifest.JSON"))
        try expect(shouldReload(path: "/x/y/mod.MJS"))
    }

    test("predicate rejects runtime data files (regression: digup.db-wal cycling)") {
        try expect(!shouldReload(path: "/x/y/sd.sqlite"))
        try expect(!shouldReload(path: "/x/y/sd.sqlite-wal"))
        try expect(!shouldReload(path: "/x/y/digup.db-wal"))
        try expect(!shouldReload(path: "/x/y/sd.settings.plist"))
        try expect(!shouldReload(path: "/x/y/stack.pid"))
        try expect(!shouldReload(path: "/x/y/stack.lock"))
        try expect(!shouldReload(path: "/x/y/stack.log"))
    }

    test("predicate rejects extensionless and dotfile paths") {
        try expect(!shouldReload(path: "/x/y/README"))
        try expect(!shouldReload(path: "/x/y/Makefile"))
        try expect(!shouldReload(path: "/x/y/.DS_Store"))
        // .DS_Store has pathExtension "" via NSString — empty string is
        // not in the allowlist, so we're safe.
        try expectEqual(("/x/y/.DS_Store" as NSString).pathExtension, "")
    }

    test("predicate handles paths with no directory component") {
        try expect(shouldReload(path: "index.html"))
        try expect(!shouldReload(path: "stack.db"))
    }
}
