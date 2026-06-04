import Foundation

/// Tests for the `headless: true` manifest field — first-class background-
/// only stacks. The host-side rendering (no chrome, 1×1 invisible panel,
/// click-through forced on) is exercised by the impure StackHost path;
/// here we pin the manifest decode + StackDoctor contract.
func registerHeadlessStackTests() {
    test("manifest: headless defaults to nil when missing") {
        let json = """
        {"id":"x","name":"X","size":{"w":1,"h":1},"permissions":[]}
        """
        let m = try JSONDecoder().decode(StackManifest.self, from: Data(json.utf8))
        try expectEqual(m.headless, nil)
        try expectEqual(m.headless == true, false)
    }

    test("manifest: headless:true decodes without requiring size") {
        // The whole point — authors stop declaring size/anchor/clickThrough
        // for background-only stacks. Decoding must succeed with only the
        // mandatory identity fields.
        let json = """
        {"id":"x","name":"X","permissions":[],"headless":true}
        """
        let m = try JSONDecoder().decode(StackManifest.self, from: Data(json.utf8))
        try expectEqual(m.headless, true)
        try expectEqual(m.size == nil, true)
        try expectEqual(m.anchor == nil, true)
    }

    test("StackDoctor: headless:true alone passes (no spurious size warning)") {
        let dir = makeTempStack(manifest: """
        {"id":"hl1","name":"HL1","permissions":[],"headless":true}
        """, indexHTML: "<html></html>")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let issues = StackDoctor.check(stackDir: dir)
        try expectEqual(issues, 0)
    }

    test("StackDoctor: headless:true + size warns (size is ignored)") {
        let dir = makeTempStack(manifest: """
        {"id":"hl2","name":"HL2","permissions":[],"headless":true,"size":{"w":1,"h":1}}
        """, indexHTML: "<html></html>")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let issues = StackDoctor.check(stackDir: dir)
        try expectEqual(issues >= 1, true)
    }

    test("StackDoctor: headless:true + anchor + clickThrough warns about both") {
        let dir = makeTempStack(manifest: """
        {"id":"hl3","name":"HL3","permissions":[],"headless":true,
         "anchor":{"edge":"top-left","inset":[0,0]},"clickThrough":true}
        """, indexHTML: "<html></html>")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let issues = StackDoctor.check(stackDir: dir)
        try expectEqual(issues >= 2, true)
    }

    test("StackDoctor: non-headless still requires size (regression guard)") {
        let dir = makeTempStack(manifest: """
        {"id":"hl4","name":"HL4","permissions":[]}
        """, indexHTML: "<html></html>")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let issues = StackDoctor.check(stackDir: dir)
        try expectEqual(issues >= 1, true)
    }

    test("StackDoctor: headless of wrong type (string) errors") {
        let dir = makeTempStack(manifest: """
        {"id":"hl5","name":"HL5","permissions":[],"headless":"yes"}
        """, indexHTML: "<html></html>")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let issues = StackDoctor.check(stackDir: dir)
        try expectEqual(issues >= 1, true)
    }
}

/// Build a throwaway stack dir with a manifest + index.html so StackDoctor
/// has something to walk. Uses /tmp + a UUID so concurrent test runs don't
/// stomp each other. Caller is responsible for cleanup via defer.
private func makeTempStack(manifest: String, indexHTML: String) -> String {
    let base = NSTemporaryDirectory() + "stackd-headless-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    try? manifest.write(toFile: base + "/stack.json", atomically: true, encoding: .utf8)
    try? indexHTML.write(toFile: base + "/index.html", atomically: true, encoding: .utf8)
    return base
}
