import Foundation

// Tests for `Sources/DataSources/Proc.swift`.
//
// Proc has two public entry points plus a handle type:
//   - Proc.exec(cmd:args:input:timeoutSeconds:completion:)
//       Launches a subprocess, drains stdout/stderr to completion, hops to
//       main for the success callback. Launch FAILURE (bad cmd / not
//       executable) invokes `completion` SYNCHRONOUSLY with
//       { code: -1, stdout: "", stderr: "stackd: failed to launch ..." }.
//   - Proc.stream(cmd:args:env:cwd:onEvent:) -> ProcStreamHandle?
//       Same launch contract but progressive: returns nil on launch
//       failure (events still emit asynchronously). On success returns a
//       handle whose cancel() sends SIGTERM.
//   - ProcStreamHandle.cancel() — idempotent; second call no-ops.
//
// The harness does not drain a RunLoop (see Tests/ThumbnailsTests.swift
// preamble), so we can only observe SYNCHRONOUS behavior:
//   1. Launch failure path of exec fires completion inline.
//   2. Launch success path of exec does NOT fire completion inline.
//   3. Launch failure path of stream returns nil.
//   4. Launch success path of stream returns a non-nil handle.
//   5. cancel() is safe to call once, twice, and after the process has
//      already been terminated by other means.
//
// What we deliberately do NOT test:
//   - The async stdout/stderr capture itself — that requires draining
//     main, which the harness contract forbids.
//   - The timeoutSeconds watchdog — same async limitation.
//   - Env / cwd propagation visible to the child — would need the child
//     to write somewhere observable, then we'd have to await its output.
//   - AppleScript / Shortcuts — separate entry points, separate file.
//
// Subprocess choices: /usr/bin/true and /bin/echo are deterministic,
// fast (<10ms), and present on every macOS install. We never spawn
// anything that touches user state (no osascript, no pmset, no
// shortcuts CLI, no networking).

func registerProcTests() {
    // MARK: - Proc.exec launch failure (synchronous)

    test("Proc.exec invokes completion synchronously with code -1 when the cmd path doesn't exist") {
        // The `catch` branch on task.run() runs completion inline before
        // returning. This is the one observable sync contract of exec —
        // Bridge.respond() depends on it firing exactly once whether the
        // failure was sync or async.
        var fired = false
        var captured: [String: Any] = [:]
        Proc.exec(
            cmd: "/usr/bin/definitely-not-a-real-binary-\(UUID().uuidString)",
            args: []
        ) { result in
            fired = true
            captured = result
        }
        try expect(fired, "launch-failure path must fire completion synchronously")
        try expectEqual(captured["code"] as? Int, -1)
        try expectEqual(captured["stdout"] as? String, "")
        guard let stderr = captured["stderr"] as? String else {
            throw Expectation(message: "stderr must be a String on launch failure")
        }
        try expect(stderr.hasPrefix("stackd: failed to launch "),
                   "expected stderr to start with 'stackd: failed to launch ', got: \(stderr)")
    }

    test("Proc.exec launch failure on an empty cmd path also fires synchronously") {
        // Empty launchPath is a degenerate caller mistake (Bridge defaults
        // missing cmd to ""), but it must NOT crash and must surface as the
        // same code: -1 launch-failure shape.
        var fired = false
        var captured: [String: Any] = [:]
        Proc.exec(cmd: "", args: []) { result in
            fired = true
            captured = result
        }
        try expect(fired, "empty cmd must fire completion synchronously, not throw")
        try expectEqual(captured["code"] as? Int, -1)
    }

    // MARK: - Proc.exec launch success (asynchronous)

    test("Proc.exec on /usr/bin/true does NOT fire completion synchronously") {
        // task.run() succeeds → completion is queued via DispatchQueue.main.
        // The harness body returns before main drains, so we observe the
        // negative: completion must NOT fire inline. If a future change
        // ever makes the success path synchronous, this flips and the
        // Bridge.respond contract needs revisiting.
        var fired = false
        Proc.exec(cmd: "/usr/bin/true", args: []) { _ in fired = true }
        try expect(!fired, "success path must be async; completion fired inline")
    }

    test("Proc.exec on /bin/echo with input does NOT fire completion synchronously") {
        // Same success-path contract, plus exercises the stdin pipe branch
        // (input != nil && !isEmpty) — that branch dispatches the write to
        // a background queue, so it must not block or invoke completion
        // before returning.
        var fired = false
        Proc.exec(
            cmd: "/bin/echo",
            args: ["hello"],
            input: "ignored-by-echo"
        ) { _ in fired = true }
        try expect(!fired)
    }

    // MARK: - Proc.stream launch failure / success (synchronous handle shape)

    test("Proc.stream returns nil when the cmd path doesn't exist") {
        // The launch-failure branch returns nil after queueing a stderr +
        // exit event onto main. We can't observe the events (they go to
        // main, harness doesn't drain), but the nil return is the
        // synchronous half of the contract — Bridge.swift checks for it
        // before inserting into procStreamHandles.
        let handle = Proc.stream(
            cmd: "/usr/bin/definitely-not-a-real-binary-\(UUID().uuidString)",
            args: [],
            env: nil,
            cwd: nil
        ) { _ in }
        try expect(handle == nil, "bad cmd path must return nil handle")
    }

    test("Proc.stream returns a non-nil handle for /usr/bin/true and cancel() is idempotent") {
        // Success path returns a handle synchronously; cancel() takes the
        // internal NSLock and short-circuits subsequent calls via the
        // `cancelled` flag. We exercise the lock + flag by calling cancel
        // multiple times back-to-back — a regression here (e.g. lock not
        // re-entrant-safe across the cancelled guard, or terminate() called
        // on a freed process) would crash or hang.
        let handle = Proc.stream(
            cmd: "/usr/bin/true",
            args: [],
            env: nil,
            cwd: nil
        ) { _ in }
        guard let handle = handle else {
            throw Expectation(message: "/usr/bin/true should launch successfully")
        }
        handle.cancel()
        handle.cancel() // second call must no-op, not crash
        handle.cancel() // third call must also no-op
    }

    test("Proc.stream accepts env and cwd overrides without crashing on launch success") {
        // env: [:] empties PATH for the child but doesn't affect launch
        // (Process uses launchPath, not PATH resolution); cwd: "/" is a
        // universally readable directory. We're not asserting the child
        // sees them — that needs async drain — only that the synchronous
        // launch + handle-return path tolerates non-nil env / cwd.
        let handle = Proc.stream(
            cmd: "/usr/bin/true",
            args: [],
            env: ["STACKD_TEST_MARKER": "1"],
            cwd: "/"
        ) { _ in }
        try expect(handle != nil, "/usr/bin/true with env+cwd should still launch")
        handle?.cancel()
    }

    test("Proc.stream tolerates a tilde-prefixed cwd via expandingTildeInPath") {
        // cwd is expanded with expandingTildeInPath before being handed to
        // currentDirectoryURL. "~" → home dir, which exists on every macOS
        // install. The launch must succeed and return a handle; a bad
        // expansion would either crash on URL construction or fall through
        // to the launch-failure branch (returning nil).
        let handle = Proc.stream(
            cmd: "/usr/bin/true",
            args: [],
            env: nil,
            cwd: "~"
        ) { _ in }
        try expect(handle != nil, "tilde-expanded cwd should launch successfully")
        handle?.cancel()
    }
}
