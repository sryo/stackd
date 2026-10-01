import Foundation

// FileWatcher drives hot reload from FSEvents. Its one policy is which
// changes count: stack-source extensions (and directory create/rename/
// remove) reload; runtime data files a stack writes into its own folder
// (SQLite WALs, plists, .log/.pid/.lock) must not, or every commit would
// cycle every stack.
//
// The extension allowlist is private and applied inside the FSEvents C
// callback, so this is exercised end-to-end against a throwaway temp
// directory that is removed afterwards.

private func spinMainRunLoop(for seconds: TimeInterval, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

func registerFileWatcherTests() {
    test("FileWatcher fires for stack-source edits (any case) but not for runtime data files") {
        let fm = FileManager.default
        let created = fm.temporaryDirectory.appendingPathComponent("stackd-filewatcher-\(UUID().uuidString)")
        try fm.createDirectory(at: created, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: created) }
        // FSEvents reports canonical paths; watch the /private/var form
        // rather than the /var symlink the temp directory API hands back.
        guard let real = realpath(created.path, nil) else {
            throw Expectation(message: "realpath failed for \(created.path)")
        }
        let dir = URL(fileURLWithPath: String(cString: real))
        free(real)

        var fires = 0
        let watcher = FileWatcher(paths: [dir.path], debounceMs: 50) { fires += 1 }
        defer { watcher.stop() }
        // The temp directory's own creation event can still be in flight when
        // the stream starts, and directory events reload by design. Let it
        // drain before measuring.
        spinMainRunLoop(for: 0.6)
        fires = 0

        for name in ["data.db", "data.db-wal", "sd.sqlite-shm", "settings.plist", "stack.log", "stack.pid", ".DS_Store"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        // FSEvents latency (0.2s) + debounce (50ms), with generous headroom.
        spinMainRunLoop(for: 1.0)
        try expectEqual(fires, 0, "runtime data files must not trigger a reload")

        try Data("x".utf8).write(to: dir.appendingPathComponent("index.JS"))
        spinMainRunLoop(for: 3.0, until: { fires > 0 })
        try expect(fires >= 1, "a stack-source edit should trigger a reload")
    }

    test("FileWatcher skips a folder the daemon moves itself, but still sees other changes") {
        let fm = FileManager.default
        let created = fm.temporaryDirectory.appendingPathComponent("stackd-filewatcher-\(UUID().uuidString)")
        try fm.createDirectory(at: created, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: created) }
        guard let real = realpath(created.path, nil) else {
            throw Expectation(message: "realpath failed for \(created.path)")
        }
        let root = URL(fileURLWithPath: String(cString: real))
        free(real)
        let watched = root.appendingPathComponent("stacks")
        let parked = root.appendingPathComponent("disabled")
        try fm.createDirectory(at: watched.appendingPathComponent("bar"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: watched.appendingPathComponent("bar/stack.json"))
        try fm.createDirectory(at: parked, withIntermediateDirectories: true)

        var fires = 0
        let watcher = FileWatcher(paths: [watched.path], debounceMs: 50) { fires += 1 }
        defer { watcher.stop() }
        spinMainRunLoop(for: 0.6)
        fires = 0

        watcher.ignore(watched.appendingPathComponent("bar").path)
        try fm.moveItem(at: watched.appendingPathComponent("bar"), to: parked.appendingPathComponent("bar"))
        spinMainRunLoop(for: 1.0)
        try expectEqual(fires, 0, "the ignored folder's move must not reload")

        try fm.createDirectory(at: watched.appendingPathComponent("other"), withIntermediateDirectories: true)
        spinMainRunLoop(for: 3.0, until: { fires > 0 })
        try expect(fires >= 1, "an unrelated new folder still reloads")
    }
}
