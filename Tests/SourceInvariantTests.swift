import Foundation

// Source-level guards for three rules that a unit test cannot exercise
// without driving macOS itself: registering a Carbon hot key would shadow a
// real shortcut, activating an app would take the user's focus, and a replay
// payload only goes wrong once a stack's page evaluates it. Each guard reads
// Sources/ and fails if the shape that keeps the rule is lost; every scan is
// also run on small samples so a pattern that stops matching fails loudly
// instead of passing on an empty result.
//
// Tests run from the repo root (tests.sh does), so `Sources/` is relative.

private struct CodeLine {
    let file: String
    let number: Int
    let text: String
    var site: String { "\(file):\(number)" }
}

/// Code lines of `text`: whole-line comments are dropped and a trailing
/// `//` comment is cut off.
private func codeLines(_ text: String, file: String) -> [CodeLine] {
    var out: [CodeLine] = []
    for (i, raw) in text.components(separatedBy: "\n").enumerated() {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
        var code = raw
        if let comment = code.range(of: " //") { code = String(code[..<comment.lowerBound]) }
        out.append(CodeLine(file: file, number: i + 1, text: code))
    }
    return out
}

private func sourceFiles() -> [(path: String, text: String)] {
    guard let walker = FileManager.default.enumerator(atPath: "Sources") else { return [] }
    var out: [(path: String, text: String)] = []
    for case let rel as String in walker where rel.hasSuffix(".swift") {
        let path = "Sources/" + rel
        if let text = try? String(contentsOfFile: path, encoding: .utf8) { out.append((path, text)) }
    }
    return out.sorted { $0.path < $1.path }
}

private func sourceCode() throws -> [CodeLine] {
    let files = sourceFiles()
    try expect(!files.isEmpty, "no Swift files under Sources/ (run the tests from the repo root)")
    return files.flatMap { codeLines($0.text, file: $0.path) }
}

private func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern)
}

private func firstMatch(_ re: NSRegularExpression, in s: String) -> NSTextCheckingResult? {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
}

private func describe(_ lines: [CodeLine]) -> [String] {
    lines.map { "\($0.site): \($0.text.trimmingCharacters(in: .whitespaces))" }
}

// MARK: - stackd never activates itself

// `.accessory` policy plus non-activating panels keep stackd from ever
// becoming the frontmost app. Any of these calls would make it frontmost.
private let activatesStackd: [NSRegularExpression] = [
    #"\bNSApp\s*\.\s*activate"#,
    #"\bNSApplication\.shared\s*\.\s*activate"#,
    #"\.activate\(\s*ignoringOtherApps"#,
    #"\bNSRunningApplication\.current\b.*\.activate"#,
].map(regex)

private func stackdActivations(in lines: [CodeLine]) -> [CodeLine] {
    lines.filter { line in activatesStackd.contains { firstMatch($0, in: line.text) != nil } }
}

// MARK: - activating another app

// stackd is never frontmost, and AppKit silently ignores activate(options:)
// from a process that is not frontmost unless .activateIgnoringOtherApps is
// among the options. Without it focusing an app does nothing.
private let activateOptions = regex(#"\.activate\(options:\s*([^)]*)\)"#)

private func activations(in lines: [CodeLine]) -> (total: Int, missingOverride: [CodeLine]) {
    var total = 0
    var missing: [CodeLine] = []
    for line in lines {
        guard let m = firstMatch(activateOptions, in: line.text),
              let r = Range(m.range(at: 1), in: line.text) else { continue }
        total += 1
        if !line.text[r].contains("activateIgnoringOtherApps") { missing.append(line) }
    }
    return (total, missing)
}

// MARK: - chords shared across stack instances

/// What is wrong with how `HotkeyRegistry.bind` shares one Carbon
/// registration between identical chords. Carbon hot keys are process-wide,
/// so a stack on N displays (N bridges) binds the same chord N times; a bind
/// that registers again fails and leaves the chord owned by whichever
/// instance won the race.
///
/// The shape that prevents it: `bind` looks for an existing registration of
/// the chord before it registers, every Token it hands out releases through
/// the reference count, and only that release unregisters.
private func hotkeySharingProblems(in source: String) -> [String] {
    let code = codeLines(source, file: "").map { $0.text }.joined(separator: "\n")
    guard let classStart = code.range(of: "final class HotkeyRegistry") else {
        return ["HotkeyRegistry is gone"]
    }
    var cls = String(code[classStart.lowerBound...])
    if let end = cls.range(of: "\n}\n") { cls = String(cls[..<end.lowerBound]) }
    guard let bindStart = cls.range(of: "func bind(spec:") else { return ["HotkeyRegistry.bind(spec:) is gone"] }
    var body = String(cls[bindStart.upperBound...])
    if let next = body.range(of: #"\n    (?:private |fileprivate )?func "#, options: .regularExpression) {
        body = String(body[..<next.lowerBound])
    }

    var problems: [String] = []
    let lookup = body.range(of: "hotkeyIdByCombo[")
    let register = body.range(of: "RegisterEventHotKey(")
    if register == nil {
        problems.append("bind no longer calls RegisterEventHotKey; update this guard with the new registration path")
    }
    if lookup == nil {
        problems.append("bind never looks up an existing registration of the same chord")
    }
    if let l = lookup, let r = register, l.lowerBound > r.lowerBound {
        problems.append("bind registers the chord with Carbon before checking whether it is already registered")
    }

    let tokens = body.components(separatedBy: "\n").filter { $0.contains("return Token") }
    if tokens.isEmpty { problems.append("bind returns no Token") }
    for t in tokens where !t.contains("releaseCombo(") {
        problems.append("a Token from bind unregisters directly instead of through the reference count: \(t.trimmingCharacters(in: .whitespaces))")
    }

    let unbinds = cls.components(separatedBy: "unbind(id:").count - 1
    let declarations = cls.components(separatedBy: "func unbind(id:").count - 1
    if unbinds - declarations != 1 {
        problems.append("unbind(id:) is called from \(unbinds - declarations) places; only the last release of a chord may unregister it")
    }
    return problems
}

// MARK: - replay payloads

// `replayState()` pushes `lastState[channel]` into the page verbatim as
// `__sd_push("name", <RAW>)`. Anything stored there that is not JSON, such as
// a bare marker string, is evaluated as JavaScript and throws a
// ReferenceError in every stack that replays that channel. So the only things
// allowed into `lastState` are Bridge.jsonify output, held in a variable or
// produced inline; flags and markers belong in their own properties.
private let lastStateWrite = regex(#"\blastState\[[^\]]+\]\s*=(?!=)\s*(.+?)\s*\{?\s*$"#)
private let jsonifyOutput = regex(#"^(?:[A-Za-z_]\w*|Bridge\.jsonify\(.*\))$"#)

private func lastStateWrites(in lines: [CodeLine]) -> (total: Int, notJSON: [CodeLine]) {
    var total = 0
    var bad: [CodeLine] = []
    for line in lines {
        guard let m = firstMatch(lastStateWrite, in: line.text),
              let r = Range(m.range(at: 1), in: line.text) else { continue }
        total += 1
        if firstMatch(jsonifyOutput, in: String(line.text[r])) == nil { bad.append(line) }
    }
    return (total, bad)
}

func registerSourceInvariantTests() {
    // MARK: never frontmost

    test("never frontmost: no source activates stackd itself") {
        let hits = stackdActivations(in: try sourceCode())
        try expect(hits.isEmpty, "stackd must never become frontmost; remove: \(describe(hits))")
    }

    test("never frontmost: the activation scan flags each way of activating stackd and ignores other apps") {
        let flagged = [
            "NSApp.activate(ignoringOtherApps: true)",
            "NSApp.activateIgnoringOtherApps(true)",
            "NSApplication.shared.activate(ignoringOtherApps: true)",
            "app.activate(ignoringOtherApps: true)",
            "NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])",
        ]
        for s in flagged {
            try expectEqual(stackdActivations(in: codeLines(s, file: "sample")).count, 1, s)
        }
        let allowed = [
            "return app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])",
            "// NSApp.activate(ignoringOtherApps: true)",
            "let n = 1 // NSApp.activate(ignoringOtherApps: true)",
        ]
        for s in allowed {
            try expectEqual(stackdActivations(in: codeLines(s, file: "sample")).count, 0, s)
        }
    }

    test("never frontmost: stackd runs as an accessory app") {
        let lines = try sourceCode()
        let policies = lines.filter { $0.text.contains("setActivationPolicy(") }
        try expect(policies.contains { $0.text.contains("setActivationPolicy(.accessory)") },
                   "nothing sets the .accessory activation policy")
        let other = policies.filter { !$0.text.contains("setActivationPolicy(.accessory)") }
        try expect(other.isEmpty, "stackd must stay .accessory; found \(describe(other))")
    }

    // MARK: activating another app

    test("activating another app from the accessory daemon passes .activateIgnoringOtherApps") {
        let found = activations(in: try sourceCode())
        try expect(found.total >= 1, "no activate(options:) call found; update this guard if app focusing moved")
        try expect(found.missingOverride.isEmpty,
                   "activate(options:) is silently ignored by a process that is not frontmost unless it includes .activateIgnoringOtherApps: \(describe(found.missingOverride))")
    }

    test("the activation-options scan flags a bare .activateAllWindows and accepts the override") {
        let bare = "return app.activate(options: [.activateAllWindows])"
        let good = "return app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])"
        let bareResult = activations(in: codeLines(bare, file: "sample"))
        try expectEqual(bareResult.total, 1)
        try expectEqual(bareResult.missingOverride.count, 1)
        let goodResult = activations(in: codeLines(good, file: "sample"))
        try expectEqual(goodResult.total, 1)
        try expectEqual(goodResult.missingOverride.count, 0)
    }

    // MARK: hotkey chord sharing

    test("hotkey sharing: identical chords share one Carbon registration until the last token is released") {
        let files = sourceFiles()
        try expect(!files.isEmpty, "no Swift files under Sources/ (run the tests from the repo root)")
        let owners = files.filter { $0.text.contains("final class HotkeyRegistry") }
        try expectEqual(owners.count, 1, "expected exactly one file declaring HotkeyRegistry")
        let problems = hotkeySharingProblems(in: owners[0].text)
        try expect(problems.isEmpty, "\(owners[0].path): \(problems)")
    }

    test("the hotkey sharing scan flags binds that register twice or unregister per token") {
        let shared = """
        final class HotkeyRegistry {
            func bind(spec: String) -> Token? {
                let combo = (UInt64(keyCode) << 32) | UInt64(mods)
                if let ownerId = hotkeyIdByCombo[combo] {
                    return Token { [weak self] in self?.releaseCombo(combo) }
                }
                let status = RegisterEventHotKey(keyCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
                hotkeyIdByCombo[combo] = id
                return Token { [weak self] in self?.releaseCombo(combo) }
            }

            func enterMode(_ name: String) {}

            private func releaseCombo(_ combo: UInt64) {
                unbind(id: id)
            }

            private func unbind(id: UInt32) {}
        }
        """
        try expectEqual(hotkeySharingProblems(in: shared), [])

        // The shape before chords were shared: every bind registers, every
        // Token unregisters its own id.
        let perBind = shared
            .replacingOccurrences(of: "if let ownerId = hotkeyIdByCombo[combo] {", with: "if false {")
            .replacingOccurrences(of: "hotkeyIdByCombo[combo] = id", with: "ids[combo] = id")
            .replacingOccurrences(of: "self?.releaseCombo(combo)", with: "self?.unbind(id: id)")
        let problems = hotkeySharingProblems(in: perBind)
        try expect(problems.count >= 3, "the pre-sharing shape should trip several checks, got \(problems)")

        let registersFirst = """
        final class HotkeyRegistry {
            func bind(spec: String) -> Token? {
                let status = RegisterEventHotKey(keyCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
                if let ownerId = hotkeyIdByCombo[combo] { return Token { [weak self] in self?.releaseCombo(combo) } }
                return Token { [weak self] in self?.releaseCombo(combo) }
            }
            func enterMode(_ name: String) {}
            private func releaseCombo(_ combo: UInt64) { unbind(id: id) }
            private func unbind(id: UInt32) {}
        }
        """
        try expect(hotkeySharingProblems(in: registersFirst).contains { $0.contains("before checking") },
                   "a lookup after RegisterEventHotKey must be flagged")
    }

    // MARK: replay payloads are JSON

    test("replay: every lastState write is jsonify output, never a literal marker") {
        let found = lastStateWrites(in: try sourceCode())
        try expect(found.total >= 5, "found only \(found.total) lastState writes; update this guard if channel state moved")
        try expect(found.notJSON.isEmpty,
                   "replayState() pushes lastState values into the page verbatim, so each must be JSON from Bridge.jsonify: \(describe(found.notJSON))")
    }

    test("the lastState scan flags a literal marker and accepts jsonify output") {
        let flagged = [
            #"self.lastState["windowsChanged"] = "primed""#,
            #"self.lastState["x"] = json ?? "null""#,
            #"lastState["y"] = String(count)"#,
        ]
        for s in flagged {
            let r = lastStateWrites(in: codeLines(s, file: "sample"))
            try expectEqual(r.total, 1, s)
            try expectEqual(r.notJSON.count, 1, s)
        }
        let accepted = [
            #"self.lastState[name] = json"#,
            #"self.lastState["displaysChanged"] = deltaJson"#,
            #"self.lastState["a"] = Bridge.jsonify(payload)"#,
            #"if json != self.lastState["media"] { return }"#,
            #"guard json != self.lastState[name] else { return }"#,
            #"if json == self.lastState["displays"] { return }"#,
        ]
        for s in accepted {
            let r = lastStateWrites(in: codeLines(s, file: "sample"))
            try expectEqual(r.notJSON.count, 0, s)
        }
    }
}
