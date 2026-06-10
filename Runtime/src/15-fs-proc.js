sd.fs = {
    // Imperative — paths support ~ expansion.
    //   await sd.fs.read("~/Notes/today.md")                    // utf8 string
    //   await sd.fs.read("/tmp/cover.png", { encoding: "base64" }) // binary-safe
    // utf8 returns null on non-UTF-8 bytes; base64 always returns a string
    // (empty for a zero-byte file).
    read(path, opts) {
      const o = opts || {};
      return request({ type: "fs.read", path, encoding: o.encoding || "utf8" });
    },
    stat(path)      { return request({ type: "fs.stat", path }); },
    list(dir, opts) { return request({ type: "fs.list", dir, hidden: !!(opts && opts.hidden) }); },
    // Write is atomic (temp-file then rename) so half-written contents never
    // appear to readers or to FSEvents-driven reloaders. mkdir is mkdir -p.
    // delete is recursive. move is rename (fails if dst exists).
    write(path, contents) { return request({ type: "fs.write", path, contents: String(contents ?? "") }); },
    mkdir(path)           { return request({ type: "fs.mkdir", path }); },
    delete(path)          { return request({ type: "fs.delete", path }); },
    move(from, to)        { return request({ type: "fs.move", from, to }); },
    // Push — returns a watchId you pass to unwatch(). Callback receives
    // an array of { kind, path } events (coalesced by FSEvents at ~100ms).
    async watch(path, fn) {
      const watchId = nextRequestId++;
      fsHandlers.set(watchId, fn);
      const ok = await request({ type: "fs.watch.start", path, watchId });
      if (!ok) { fsHandlers.delete(watchId); return null; }
      return watchId;
    },
    async unwatch(watchId) {
      fsHandlers.delete(watchId);
      return request({ type: "fs.watch.stop", watchId });
    },
    // Extended attributes — Darwin getxattr / setxattr / listxattr / removexattr.
    // Get / set use base64 for the raw bytes so binary plist payloads (Finder
    // tags under `com.apple.metadata:_kMDItemUserTags`, download provenance
    // under `com.apple.metadata:kMDItemWhereFroms`) survive the IPC.
    //   const b64 = await sd.fs.xattr.get(path, "com.apple.metadata:kMDItemWhereFroms");
    //   // → "YnBsaXN0MDDU..." | null
    //   // Decode in stack code: atob(b64) → raw bytes → binary-plist parser.
    //   await sd.fs.xattr.set(path, "com.apple.FinderInfo", btoa(rawBytes));
    //   await sd.fs.xattr.list(path);   // ["com.apple.metadata:kMDItemWhereFroms", ...]
    //   await sd.fs.xattr.remove(path, "com.apple.quarantine");
    // No auto-decoding in v1 — every Apple xattr is binary plist or raw bytes;
    // shipping a plist parser inside the daemon would lock in a v2 surface
    // before the consumers are known. Gated by the same "fs" permission as
    // the rest of sd.fs.
    xattr: {
      get(path, name)        { return request({ type: "fs.xattr.get",    path, name }); },
      set(path, name, value) { return request({ type: "fs.xattr.set",    path, name, value: String(value ?? "") }); },
      list(path)             { return request({ type: "fs.xattr.list",   path }); },
      remove(path, name)     { return request({ type: "fs.xattr.remove", path, name }); }
    }
  };
sd.pasteboard = {
    changed:   channel("pasteboard"),                       // signal: {text, changeCount}
    get()      { return request({ type: "pasteboard.get" }); },
    set(value) { return request({ type: "pasteboard.set", value }); }
  };
sd.proc = {
    // exec(cmd, args, opts?) → Promise<{code, stdout, stderr}>
    // opts: { input?: string, timeout?: seconds }
    exec(cmd, args, opts) {
      return request({
        type: "proc.exec",
        cmd, args: args || [],
        input: opts && opts.input,
        timeout: opts && opts.timeout
      });
    },
    // Streamed counterpart of exec — progressive stdout/stderr instead of
    // buffer-to-completion. Use for long-running children where you want to
    // surface output as it arrives (tail -f, brew install, ffmpeg, etc.).
    //
    //   const h = await sd.proc.stream(
    //     { cmd: "/usr/bin/tail", args: ["-f", "/var/log/system.log"] },
    //     ({ stream, chunk, code, signal }) => {
    //       if (stream === "stdout") appendLine(chunk);
    //       if (stream === "stderr") logErr(chunk);
    //       if (stream === "exit")   console.log("done", code, signal);
    //     });
    //   ...later...
    //   await h.cancel();   // SIGTERM the child; "exit" still fires.
    //
    // The callback fires once per native chunk (no line buffering — chunks
    // can split mid-line); accumulate yourself if you need full lines.
    // The "exit" event does NOT re-send buffered stdout/stderr — accumulate
    // the chunks if you want a final joined payload.
    async stream(opts, callback) {
      const o = opts || {};
      if (typeof callback !== "function") return null;
      const id = await registerHandler(procStreamHandlers, {
        type: "proc.stream.start",
        cmd:  String(o.cmd ?? ""),
        args: o.args || [],
        env:  o.env,
        cwd:  o.cwd
      }, callback);
      if (id == null) return null;
      return {
        id,
        cancel() {
          // Don't unregister yet — the exit event still needs to land. The
          // handler map deletes itself when "exit" arrives (see __sd_proc_stream_fire).
          return request({ type: "proc.stream.cancel", id });
        }
      };
    }
  };
  // AppleScript / JXA runner — faster than spawning /usr/bin/osascript for
  // every call (NSAppleScript runs in-process). Use for: scripting other apps
  // via Apple Events, querying System Events for window/UI info, anything
  // `tell application X to ...` shaped.
  //   const r = await sd.applescript.run(`return 1 + 1`);            // r.result === 2
  //   const r = await sd.applescript.run(`return Math.PI`, { language: "javascript" });
  //   const r = await sd.applescript.run(`return {1, 2, "three"}`);  // r.result === [1, 2, "three"]
  // Returns: { ok: boolean, result: any, error?: string }.
  // `result` preserves the script's return type — numbers stay numbers, lists
  // become arrays, records become objects, strings stay strings, booleans stay
  // booleans. Void returns are "" so a no-`return` script lands on a string.
sd.applescript = {
    run(source, opts) {
      return request({
        type: "applescript.run",
        source: String(source ?? ""),
        language: (opts && opts.language) || "applescript",
        timeout: (opts && opts.timeout) || 10
      });
    }
  };
  // Invoke a Shortcut by name (the user-visible name in the Shortcuts app).
  //   const r = await sd.shortcuts.run("My Shortcut");
  //   const r = await sd.shortcuts.run("Read Text", { input: "hello" });
  //   // → { stdout, stderr, exitCode }
  // The shortcut's final "Stop and output" value lands in stdout; a nonzero
  // exitCode means the run failed (unknown name, mid-shortcut error, denied
  // TCC). First call on a fresh system surfaces the Shortcuts access prompt.
sd.shortcuts = {
    run(name, opts) {
      const o = opts || {};
      return request({
        type: "shortcuts.run",
        name: String(name ?? ""),
        input: o.input,
        timeout: o.timeout
      });
    }
  };
