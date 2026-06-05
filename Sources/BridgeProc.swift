import Foundation

/// Process primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1). Three entries:
///
///   - `proc.exec` — one-shot async invocation. Returns
///     `{ stdout, stderr, exitCode }` (or the timed-out variant) via the
///     completion callback. No handle minted; pure `.custom(...)`.
///
///   - `proc.stream.start` — long-lived child process; progressive
///     stdout/stderr arrive as per-chunk callbacks fanned out through
///     `__sd_proc_stream_fire(id, payload)`. The final `exit` event drops
///     the handle so a follow-up `proc.stream.cancel` is a no-op and the
///     per-stack drain doesn't try to SIGTERM a dead child.
///
///   - `proc.stream.cancel` — sends SIGTERM. Doesn't remove the handle
///     from the table — the exit event handler does that, so a subsequent
///     cancel reports `false` only when the SIGTERM was never issued.
///
/// `procStreamHandles` and `nextProcStreamId` were widened from
/// fileprivate to internal in Bridge.swift so this file's `.custom` /
/// `.syncBridge` closures can mint and release `ProcStreamHandle`s.
/// Scope drain on stack unload (end of Bridge.swift) SIGTERMs any still-
/// running child so reload doesn't strand subprocesses.
extension Bridge {
    /// Proc primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func procPrimitives() -> [Primitive] {
        return [
            // Process exec — async; respond from the completion callback.
            .custom("proc.exec", permission: "proc") { bridge, body, requestId in
                Proc.exec(
                    cmd:     body["cmd"]   as? String ?? "",
                    args:    body["args"]  as? [String] ?? [],
                    input:   body["input"] as? String,
                    timeoutSeconds: body["timeout"] as? Double
                ) { [weak bridge] result in
                    bridge?.respond(requestId: requestId, value: result)
                }
            },

            // Streamed proc — progressive stdout/stderr via per-chunk callbacks,
            // SIGTERM via cancel. Mints an id (returned synchronously to JS);
            // each chunk + the final exit event fire via __sd_proc_stream_fire.
            // Same handle-table pattern as broadcasts.observe / hotkey.bind.
            .custom("proc.stream.start", permission: "proc") { bridge, body, requestId in
                let cmd  = body["cmd"]  as? String ?? ""
                let args = body["args"] as? [String] ?? []
                let env  = body["env"]  as? [String: String]
                let cwd  = body["cwd"]  as? String
                let id = bridge.nextProcStreamId
                bridge.nextProcStreamId += 1
                let handle = Proc.stream(cmd: cmd, args: args, env: env, cwd: cwd) { [weak bridge] payload in
                    guard let bridge = bridge, let webView = bridge.webView else { return }
                    let json = Bridge.jsonify(payload)
                    // Proc.stream already hops to main before invoking onEvent;
                    // evaluateJavaScript runs synchronously from here.
                    webView.evaluateJavaScript(
                        "window.__sd_proc_stream_fire && window.__sd_proc_stream_fire(\(id), \(json));",
                        completionHandler: nil
                    )
                    // Final event drops the handle so cancel() after exit no-ops
                    // and the per-stack drain doesn't try to SIGTERM a dead child.
                    if (payload["stream"] as? String) == "exit" {
                        bridge.procStreamHandles.removeValue(forKey: id)
                    }
                }
                guard let handle = handle else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                bridge.procStreamHandles[id] = handle
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("proc.stream.cancel", permission: "proc", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let h = b.procStreamHandles[id] else { return false }
                h.cancel()
                // Don't remove from the table here — the exit event handler does
                // that. Removing now would let a subsequent cancel slip through
                // as "not found" even though the SIGTERM was already in flight.
                return true
            },
        ]
    }
}
