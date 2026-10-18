import Foundation

// Stack compatibility: every stack folder must still load through the
// daemon's own loader (StackSource.loadFolder), pass `stackd doctor` with
// the same issue count, keep the same effective permissions (manifest ∪
// inferred) and the same stack.json keys the decoder ignores, and only
// reference `sd.*` members the runtime still builds.
//
// examples/ is pinned by Tests/Golden/stack-compat-examples.txt. The user's
// stacks (~/stackd/stacks, or $STACKD_COMPAT_ROOT/stacks) are read-only
// input: they must load and resolve, and their report is written to
// .build/stack-compat/user-stacks.txt. With STACKD_COMPAT_BASELINE=<file>
// (a report saved before a refactor) the report must match it exactly.

enum StackCompat {
    struct Row {
        let id: String
        let loads: Bool
        let doctorIssues: Int
        let permissions: [String]
        let ignoredKeys: [String]
        let unresolved: [String]

        var line: String {
            func list(_ xs: [String]) -> String { xs.isEmpty ? "-" : xs.joined(separator: ",") }
            return "\(id) load=\(loads ? "ok" : "FAIL") doctor=\(doctorIssues) perms=\(list(permissions))"
                + " ignored=\(list(ignoredKeys)) unresolved=\(list(unresolved))"
        }
    }

    /// Stack folders under `dir`, one level of grouping allowed
    /// (examples/bang-pair/bang-emitter). Ids are paths relative to `dir`.
    static func stackDirs(in dir: String) -> [String] {
        let fm = FileManager.default
        func subdirs(_ d: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { name in
                var isDir: ObjCBool = false
                return !name.hasPrefix(".") && fm.fileExists(atPath: d + "/" + name, isDirectory: &isDir) && isDir.boolValue
            }.sorted()
        }
        return subdirs(dir).flatMap { name -> [String] in
            if fm.fileExists(atPath: dir + "/" + name + "/stack.json") { return [name] }
            return subdirs(dir + "/" + name)
                .filter { fm.fileExists(atPath: dir + "/" + name + "/" + $0 + "/stack.json") }
                .map { name + "/" + $0 }
        }
    }

    static func rows(stacksDir: String, defaults: [String: Any]) -> [Row] {
        // Overlay page scripts ship inside the stack's source and read the
        // members the daemon injects there.
        let surface = Resolver(PublicSurface.runtimeEntries()
            + PublicSurface.overlayPageMembers().map { .init(path: "sd." + $0, kind: "value") })
        let decodedKeys = Set(PublicSurface.manifestFields().map {
            String($0.prefix { $0 != "." && $0 != " " && $0 != "[" })
        })
        return stackDirs(in: stacksDir).map { id in
            let dir = stacksDir + "/" + id
            let issues = silencingStdout { StackDoctor.check(stackDir: dir) }
            let raw = FileManager.default.contents(atPath: dir + "/stack.json")
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let ignored = Set(raw.keys).subtracting(decodedKeys).sorted()
            guard let src = StackSource.loadFolder(at: dir, defaults: defaults) else {
                return Row(id: id, loads: false, doctorIssues: issues, permissions: [],
                           ignoredKeys: ignored, unresolved: [])
            }
            let perms = Set(src.manifest.permissions).union(ChannelInference.infer(from: src.sourceText))
            let unresolved = references(in: src.sourceText).filter { !surface.resolves($0) }
            return Row(id: id, loads: true, doctorIssues: issues, permissions: perms.sorted(),
                       ignoredKeys: ignored, unresolved: unresolved.sorted())
        }
    }

    static func report(_ rows: [Row], header: String) -> String {
        ([header] + rows.map { $0.line }).joined(separator: "\n") + "\n"
    }

    /// `sd.a.b` member chains in stack code, comments removed. Same left
    /// boundary as ChannelInference (no identifier char or `.` before `sd`),
    /// plus quotes: `"sd.window.created"` is a bang name, not a member access.
    static func references(in text: String) -> Set<String> {
        let code = stripComments(text)
        let re = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_$.'"`])sd((?:\.[A-Za-z_$][A-Za-z0-9_$]*)+)"#)
        let ns = code as NSString
        var out = Set<String>()
        for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            out.insert("sd" + ns.substring(with: m.range(at: 1)))
        }
        return out
    }

    /// Drops `/* */`, `<!-- -->` and `//` comments. A `//` only starts a
    /// comment at line start or after whitespace, so `sd://runtime/api.js`
    /// and `https://…` inside strings survive.
    static func stripComments(_ text: String) -> String {
        var s = text
        for pattern in [#"/\*[\s\S]*?\*/"#, #"<!--[\s\S]*?-->"#, #"(?m)(^|\s)//.*$"#] {
            let re = try! NSRegularExpression(pattern: pattern)
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                            withTemplate: pattern.hasPrefix("(?m)") ? "$1" : " ")
        }
        return s
    }

    /// Resolves a member chain against the runtime's `sd` tree. Walking stops
    /// successfully at a signal, function or value: what follows is payload
    /// (`sd.battery.percent`) or a property of the result, unless the tree has
    /// a member by that name (`sd.mouse.warp`, `sd.bang.declare`).
    struct Resolver {
        private var kinds: [String: String] = [:]

        init(_ entries: [PublicSurface.Entry]) {
            for e in entries { kinds[e.path] = e.kind }
        }

        func resolves(_ ref: String) -> Bool {
            let segs = ref.split(separator: ".").map(String.init)
            guard segs.first == "sd" else { return false }
            var cur = "sd"
            for seg in segs.dropFirst() {
                let next = cur + "." + seg
                guard var kind = kinds[next] else {
                    let here = kinds[cur] ?? "object"
                    return here != "object"
                }
                cur = next
                if kind.hasPrefix("alias ") {
                    cur = String(kind.dropFirst("alias ".count))
                    kind = kinds[cur] ?? "object"
                }
            }
            return true
        }
    }

    /// StackDoctor prints a line per finding; keep the test log readable.
    static func silencingStdout<T>(_ body: () -> T) -> T {
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        let null = open("/dev/null", O_WRONLY)
        dup2(null, STDOUT_FILENO)
        defer {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
            close(saved); close(null)
        }
        return body()
    }
}

func registerStackCompatTests() {
    test("stack compat: resolver accepts payload fields and members, rejects unknown members") {
        let r = StackCompat.Resolver([
            .init(path: "sd", kind: "object"),
            .init(path: "sd.battery", kind: "signal"),
            .init(path: "sd.mouse", kind: "signal"),
            .init(path: "sd.mouse.warp", kind: "fn/2"),
            .init(path: "sd.windows", kind: "object"),
            .init(path: "sd.windows.focus", kind: "fn/1"),
            .init(path: "sd.timer", kind: "object"),
            .init(path: "sd.util", kind: "object"),
            .init(path: "sd.util.debounce", kind: "alias sd.timer.debounce"),
            .init(path: "sd.timer.debounce", kind: "fn/2"),
        ])
        try expect(r.resolves("sd.battery.percent"), "payload field on a signal")
        try expect(r.resolves("sd.mouse.warp"), "member on a signal")
        try expect(r.resolves("sd.windows.focus"), "function")
        try expect(r.resolves("sd.util.debounce"), "alias")
        try expect(!r.resolves("sd.windows.focusd"), "typo on an object namespace")
        try expect(!r.resolves("sd.nope"), "unknown namespace")
    }

    test("stack compat: references skip bang names, comments and foreign objects") {
        let refs = StackCompat.references(in: """
        {{ sd.battery.percent }} sd.windows.focus(id); handles("sd.window.created");
        ctx.sd.fake.thing; xsd.nope; await sd.fs.read(p) // sd.window.moved fires
        /* placed off sd.gone */ <!-- sd.html.comment --> import "sd://runtime/api.js";
        """)
        try expectEqual(refs, ["sd.battery.percent", "sd.windows.focus", "sd.fs.read"])
    }

    test("stack compat: examples/ match Tests/Golden/stack-compat-examples.txt") {
        let rows = StackCompat.rows(stacksDir: "examples", defaults: [:])
        let text = StackCompat.report(rows, header:
            "# examples/ through StackSource.loadFolder + StackDoctor + ChannelInference + the sd.* surface. Generated by Tests/StackCompatTests.swift.")
        try Golden.check(text, path: "Tests/Golden/stack-compat-examples.txt")
    }

    test("stack compat: user stacks load and resolve against the sd.* surface") {
        let env = ProcessInfo.processInfo.environment
        let root = env["STACKD_COMPAT_ROOT"] ?? (NSHomeDirectory() + "/stackd")
        let stacksDir = root + "/stacks"
        guard FileManager.default.fileExists(atPath: stacksDir) else {
            print("  (no \(stacksDir); skipped)")
            return
        }
        var defaults: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: root + "/defaults.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            defaults = obj
        }
        let rows = StackCompat.rows(stacksDir: stacksDir, defaults: defaults)
        let text = StackCompat.report(rows, header: "# \(stacksDir)")
        let out = ".build/stack-compat/user-stacks.txt"
        try? FileManager.default.createDirectory(atPath: ".build/stack-compat", withIntermediateDirectories: true)
        try? text.write(toFile: out, atomically: true, encoding: .utf8)

        let broken = rows.filter { !$0.loads || !$0.unresolved.isEmpty }
        try expect(broken.isEmpty, "user stacks that no longer load or reference missing sd.* members:\n"
                   + broken.map { "    " + $0.line }.joined(separator: "\n"))
        if let base = env["STACKD_COMPAT_BASELINE"] {
            guard let expected = try? String(contentsOfFile: base, encoding: .utf8) else {
                throw Expectation(message: "STACKD_COMPAT_BASELINE=\(base) is unreadable")
            }
            try expect(expected == text, "user stacks drifted from \(base):\n"
                       + Golden.sectionDiff(expected: expected, actual: text)
                       + "\n  full diff: diff -u \(base) \(out)")
        }
    }
}
