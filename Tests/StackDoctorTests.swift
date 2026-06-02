import Foundation

/// Characterization tests for `StackDoctor.check(stackDir:)`. Observed via
/// the returned issue count — `check` also prints diagnostics, which is fine
/// for the CLI but not what we assert on here (no stdout capture). Warnings
/// (e.g. id != folder) print but don't increment the count, so they show up
/// as 0 returns; real issues (missing fields, bad permissions, missing
/// index.html) increment.
func registerStackDoctorTests() {
    func makeTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
    func write(_ contents: String, to path: String) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    test("doctor: missing stack.json is an issue") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // No stack.json written.
        try expectEqual(StackDoctor.check(stackDir: dir), 1)
    }

    test("doctor: malformed JSON in stack.json is an issue") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write("{ not valid json", to: dir + "/stack.json")
        try expectEqual(StackDoctor.check(stackDir: dir), 1)
    }

    test("doctor: missing required fields increment issue count") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // {} omits id, name, size, and index.html — 4 issues.
        write("{}", to: dir + "/stack.json")
        try expectEqual(StackDoctor.check(stackDir: dir), 4)
    }

    test("doctor: unknown permission flagged as issue") {
        // Folder name must match id to avoid the cosmetic warning; we want to
        // isolate just the unknown-permission issue (+ the missing index.html
        // issue we can't avoid without writing the file).
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent("demo").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        write("""
        { "id": "demo", "name": "demo", "size": {"h": 24},
          "permissions": ["totally-fake-perm"] }
        """, to: dir + "/stack.json")
        write("<div/>", to: dir + "/index.html")
        try expectEqual(StackDoctor.check(stackDir: dir), 1)
    }

    test("doctor: complete + valid manifest reports 0 issues") {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent("ok").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        write("""
        { "id": "ok", "name": "ok", "size": {"h": 24},
          "permissions": ["battery", "mouse"] }
        """, to: dir + "/stack.json")
        write("<div/>", to: dir + "/index.html")
        try expectEqual(StackDoctor.check(stackDir: dir), 0)
    }

    test("doctor: known material values pass without issue") {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let cases = ["glass", "glass.clear", "glass.tinted(#ff8800)",
                     "sidebar", "hud", "vibrancy.popover", "none"]
        for (i, mat) in cases.enumerated() {
            let dir = parent.appendingPathComponent("ok\(i)").path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            write("""
            { "id": "ok\(i)", "name": "ok", "size": {"h": 24},
              "permissions": [], "material": "\(mat)" }
            """, to: dir + "/stack.json")
            write("<div/>", to: dir + "/index.html")
            try expectEqual(StackDoctor.check(stackDir: dir), 0, "material '\(mat)' should pass")
        }
    }

    test("doctor: unknown material flagged as issue") {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent("bad").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        write("""
        { "id": "bad", "name": "bad", "size": {"h": 24},
          "permissions": [], "material": "lava" }
        """, to: dir + "/stack.json")
        write("<div/>", to: dir + "/index.html")
        try expectEqual(StackDoctor.check(stackDir: dir), 1)
    }

    test("doctor: cornerRadius numeric is accepted") {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent("rad").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        write("""
        { "id": "rad", "name": "rad", "size": {"h": 24},
          "permissions": [], "cornerRadius": 12 }
        """, to: dir + "/stack.json")
        write("<div/>", to: dir + "/index.html")
        try expectEqual(StackDoctor.check(stackDir: dir), 0)
    }

    test("doctor: cornerRadius non-numeric is rejected") {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent("badcr").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        write("""
        { "id": "badcr", "name": "badcr", "size": {"h": 24},
          "permissions": [], "cornerRadius": "twelve" }
        """, to: dir + "/stack.json")
        write("<div/>", to: dir + "/index.html")
        try expectEqual(StackDoctor.check(stackDir: dir), 1)
    }

    test("doctor: id-folder mismatch is a warning, not an issue") {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent("folder-name").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        write("""
        { "id": "different-id", "name": "x", "size": {"h": 24} }
        """, to: dir + "/stack.json")
        write("<div/>", to: dir + "/index.html")
        // Warning prints but does NOT count — pinned behavior.
        try expectEqual(StackDoctor.check(stackDir: dir), 0)
    }
}
