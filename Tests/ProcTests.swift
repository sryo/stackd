import Foundation

// Tests for `Sources/DataSources/Proc.swift` — Proc.exec, Proc.stream and
// ProcStreamHandle.cancel().
//
// Completions and stream events are delivered on main, so async assertions
// spin the main run loop with a deadline. Launch failure of exec is the one
// synchronous path (completion fires inline with code -1).
//
// Subprocesses are limited to /usr/bin/true, /bin/sh, /bin/cat, /bin/sleep
// and head/yes inside sh — deterministic, fast, and present on every macOS
// install.
// Nothing touches user state (no osascript, pmset, shortcuts, networking).
//
// Not covered: AppleScript.run (separate entry point, OSAKit).

private func procSpin(timeout: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func registerProcTests() {
    // MARK: - Proc.exec

    test("Proc.exec launch failure fires completion synchronously with code -1") {
        // Launch failure (missing or empty cmd path) is the one path that
        // completes inline; Bridge relies on completion firing exactly once
        // whether the failure was sync or async.
        for cmd in ["/usr/bin/definitely-not-a-real-binary-\(UUID().uuidString)", ""] {
            var calls = 0
            var captured: [String: Any] = [:]
            Proc.exec(cmd: cmd, args: []) { result in
                calls += 1
                captured = result
            }
            try expectEqual(calls, 1, "launch failure for '\(cmd)' must complete inline exactly once")
            try expectEqual(captured["code"] as? Int, -1)
            try expectEqual(captured["stdout"] as? String, "")
            let stderr = captured["stderr"] as? String ?? ""
            try expect(stderr.contains("failed to launch"),
                       "stderr should describe the launch failure, got: \(stderr)")
        }
    }

    test("Proc.exec captures stdout, stderr and exit code asynchronously on main") {
        var result: [String: Any]?
        var onMain = false
        Proc.exec(cmd: "/bin/sh", args: ["-c", "printf out; printf err >&2; exit 3"]) { r in
            onMain = Thread.isMainThread
            result = r
        }
        try expect(result == nil, "success path must complete asynchronously, not inline")
        procSpin(timeout: 5) { result != nil }
        guard let r = result else { throw Expectation(message: "exec never completed") }
        try expect(onMain, "completion must be delivered on main")
        try expectEqual(r["code"] as? Int, 3)
        try expectEqual(r["stdout"] as? String, "out")
        try expectEqual(r["stderr"] as? String, "err")
    }

    test("Proc.exec pipes input to the child's stdin") {
        var result: [String: Any]?
        Proc.exec(cmd: "/bin/cat", args: [], input: "piped-input") { result = $0 }
        procSpin(timeout: 5) { result != nil }
        try expectEqual(result?["code"] as? Int, 0)
        try expectEqual(result?["stdout"] as? String, "piped-input")
    }

    test("Proc.exec timeoutSeconds terminates a long-running child") {
        // SIGTERM death reports the signal number (15) as the exit code.
        var result: [String: Any]?
        let start = Date()
        Proc.exec(cmd: "/bin/sleep", args: ["30"], timeoutSeconds: 0.2) { result = $0 }
        procSpin(timeout: 5) { result != nil }
        guard let r = result else { throw Expectation(message: "timeout watchdog never fired") }
        try expect(Date().timeIntervalSince(start) < 5, "child outlived its timeout")
        try expectEqual(r["code"] as? Int, 15)
    }

    test("Proc.exec drains stderr concurrently so a chatty stderr can't deadlock the child") {
        // 200KB is several times the pipe buffer; reading stdout to EOF
        // before touching stderr would leave the child blocked on write.
        // The timeout is the safety net: a deadlock surfaces as code 15.
        var result: [String: Any]?
        Proc.exec(cmd: "/bin/sh", args: ["-c", "head -c 200000 /dev/zero >&2; echo ok"],
                  timeoutSeconds: 4) { result = $0 }
        procSpin(timeout: 8) { result != nil }
        guard let r = result else { throw Expectation(message: "exec never completed") }
        try expectEqual(r["code"] as? Int, 0)
        try expectEqual(r["stdout"] as? String, "ok\n")
        try expectEqual((r["stderr"] as? String)?.utf8.count, 200000)
    }

    // MARK: - Proc.stream

    test("Proc.stream returns nil when the cmd path doesn't exist") {
        // Bridge checks the nil return before tracking a handle.
        let handle = Proc.stream(
            cmd: "/usr/bin/definitely-not-a-real-binary-\(UUID().uuidString)",
            args: [], env: nil, cwd: nil
        ) { _ in }
        try expect(handle == nil, "bad cmd path must return nil handle")
    }

    test("Proc.stream emits stdout chunks then an exit event, honoring env and a tilde cwd") {
        var stdout = ""
        var exitEvent: [String: Any]?
        let handle = Proc.stream(
            cmd: "/bin/sh",
            args: ["-c", "printf \"$STACKD_TEST_MARKER|\"; pwd"],
            env: ["STACKD_TEST_MARKER": "marker-1"],
            cwd: "~"
        ) { event in
            switch event["stream"] as? String {
            case "stdout": stdout += event["chunk"] as? String ?? ""
            case "exit":   exitEvent = event
            default:       break
            }
        }
        try expect(handle != nil, "/bin/sh should launch")
        procSpin(timeout: 5) { exitEvent != nil }
        try expectEqual(exitEvent?["code"] as? Int, 0)
        try expect(exitEvent?["signal"] == nil, "clean exit must not carry a signal")
        let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
        let printed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(printed.hasPrefix("marker-1|"), "env not propagated: \(printed)")
        let cwd = (String(printed.dropFirst("marker-1|".count)) as NSString).resolvingSymlinksInPath
        try expectEqual(cwd, home, "cwd '~' should expand to the home directory")
    }

    test("ProcStreamHandle.cancel sends SIGTERM once and the exit event reports the signal") {
        var exits: [[String: Any]] = []
        guard let handle = Proc.stream(cmd: "/bin/sleep", args: ["30"], env: nil, cwd: nil,
                                       onEvent: { event in
            if event["stream"] as? String == "exit" { exits.append(event) }
        }) else {
            throw Expectation(message: "/bin/sleep should launch")
        }
        handle.cancel()
        handle.cancel() // idempotent
        procSpin(timeout: 5) { !exits.isEmpty }
        procSpin(timeout: 0.1) { false } // let any duplicate exit event land
        try expectEqual(exits.count, 1, "exactly one exit event")
        try expectEqual(exits.first?["signal"] as? Int, 15)
    }

    test("Proc.stream delivers every chunk before the exit event") {
        // The backgrounded subshell keeps both pipes open and writes after
        // sh itself exits — output must keep flowing until the pipes hit
        // EOF, and only then does "exit" fire.
        var stdout = ""
        var chunksAfterExit = 0
        var exited = false
        let handle = Proc.stream(
            cmd: "/bin/sh",
            args: ["-c", "(for i in 1 2 3; do sleep 0.05; echo $i; done) & echo early"],
            env: nil, cwd: nil
        ) { event in
            switch event["stream"] as? String {
            case "exit":   exited = true
            case "stdout":
                if exited { chunksAfterExit += 1 }
                stdout += event["chunk"] as? String ?? ""
            default:       break
            }
        }
        try expect(handle != nil, "/bin/sh should launch")
        procSpin(timeout: 5) { exited }
        try expect(exited, "exit event never fired")
        procSpin(timeout: 0.3) { false } // let any straggler land
        try expectEqual(chunksAfterExit, 0, "chunks delivered after exit")
        try expectEqual(stdout, "early\n1\n2\n3\n")
    }
}
