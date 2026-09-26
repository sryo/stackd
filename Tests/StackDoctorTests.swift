import Foundation

/// Characterization tests for `StackDoctor.check(stackDir:)`. Observed via
/// the returned issue count — `check` also prints diagnostics, which is fine
/// for the CLI but not what we assert on here (no stdout capture). Warnings
/// (e.g. id != folder) print but don't increment the count, so they show up
/// as 0 returns; real issues (missing fields, bad permissions, missing
/// index.html) increment. Headless-specific rules live in HeadlessStackTests.
func registerStackDoctorTests() {
    /// Runs the doctor on a throwaway `<tmp>/<uuid>/<folder>/` containing
    /// `manifest` as stack.json (omitted when nil) and, when `index` is true,
    /// a stub index.html. The folder name matches the manifests' ids so the
    /// id/folder warning stays out of the way unless a test wants it.
    func doctor(folder: String = "demo", manifest: String?, index: Bool = true) -> Int {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent(folder).path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let manifest = manifest {
            try? manifest.write(toFile: dir + "/stack.json", atomically: true, encoding: .utf8)
        }
        if index {
            try? "<div/>".write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
        }
        return StackDoctor.check(stackDir: dir)
    }
    func manifest(_ extra: String = "") -> String {
        """
        { "id": "demo", "name": "demo", "size": {"h": 24}, "permissions": []\(extra.isEmpty ? "" : ", " + extra) }
        """
    }

    test("doctor: missing stack.json is an issue") {
        try expectEqual(doctor(manifest: nil), 1)
    }

    test("doctor: malformed JSON in stack.json is an issue") {
        try expectEqual(doctor(manifest: "{ not valid json"), 1)
    }

    test("doctor: non-object JSON root is an issue") {
        try expectEqual(doctor(manifest: "[1, 2, 3]"), 1)
    }

    test("doctor: missing required fields increment issue count") {
        // {} omits id, name, size, and index.html — 4 issues.
        try expectEqual(doctor(manifest: "{}", index: false), 4)
    }

    test("doctor: complete + valid manifest reports 0 issues") {
        try expectEqual(doctor(manifest: """
        { "id": "demo", "name": "demo", "size": {"h": 24},
          "permissions": ["battery", "mouse"] }
        """), 0)
    }

    test("doctor: unknown permission flagged as issue") {
        try expectEqual(doctor(manifest: """
        { "id": "demo", "name": "demo", "size": {"h": 24},
          "permissions": ["totally-fake-perm"] }
        """), 1)
    }

    test("doctor: permissions that isn't a string array is an issue") {
        try expectEqual(doctor(manifest: """
        { "id": "demo", "name": "demo", "size": {"h": 24}, "permissions": "battery" }
        """), 1)
    }

    test("doctor: known material values pass without issue") {
        let cases = ["glass", "glass.clear", "glass.tinted(#ff8800)",
                     "sidebar", "hud", "vibrancy.popover", "none"]
        for mat in cases {
            try expectEqual(doctor(manifest: manifest("\"material\": \"\(mat)\"")), 0,
                            "material '\(mat)' should pass")
        }
    }

    test("doctor: unknown material flagged as issue") {
        try expectEqual(doctor(manifest: manifest("\"material\": \"lava\"")), 1)
    }

    test("doctor: cornerRadius numeric is accepted, non-numeric rejected") {
        try expectEqual(doctor(manifest: manifest("\"cornerRadius\": 12")), 0)
        try expectEqual(doctor(manifest: manifest("\"cornerRadius\": \"twelve\"")), 1)
    }

    test("doctor: known shapes pass, unknown shape flagged") {
        for shape in ["rect", "rounded", "capsule"] {
            try expectEqual(doctor(manifest: manifest("\"shape\": \"\(shape)\"")), 0,
                            "shape '\(shape)' should pass")
        }
        try expectEqual(doctor(manifest: manifest("\"shape\": \"hexagon\"")), 1)
    }

    test("doctor: padding numeric is accepted, non-numeric rejected") {
        try expectEqual(doctor(manifest: manifest("\"padding\": 0")), 0)
        try expectEqual(doctor(manifest: manifest("\"padding\": \"8px\"")), 1)
    }

    test("doctor: id-folder mismatch is a warning, not an issue") {
        try expectEqual(doctor(folder: "folder-name", manifest: """
        { "id": "different-id", "name": "x", "size": {"h": 24} }
        """), 0)
    }
}
