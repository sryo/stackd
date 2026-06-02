import Foundation

/// Characterization tests for `StackSource.loadFolder(at:defaults:)`. Channel
/// inference is covered in ChannelInferenceTests; here we exercise manifest
/// loading, defaults merging, sourceText aggregation, and the failure modes
/// (missing dir, missing manifest, malformed JSON, decode failure). Required
/// manifest fields per StackManifest: id, name, size, permissions.
func registerStackSourceTests() {
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
    let minimalManifest = """
    { "id": "demo", "name": "Demo", "size": {"h": 24}, "permissions": [] }
    """

    test("loadFolder: missing directory returns nil") {
        // Path under tmp that was never created — Data(contentsOf:) for the
        // manifest fails, loadFolder returns nil.
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try expect(StackSource.loadFolder(at: ghost, defaults: [:]) == nil)
    }

    test("loadFolder: missing stack.json returns nil") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Folder exists, no manifest inside.
        try expect(StackSource.loadFolder(at: dir, defaults: [:]) == nil)
    }

    test("loadFolder: malformed JSON returns nil") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write("{ not valid json", to: dir + "/stack.json")
        try expect(StackSource.loadFolder(at: dir, defaults: [:]) == nil)
    }

    test("loadFolder: manifest missing required fields returns nil") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // {} fails StackManifest decoding (id/name/size/permissions all
        // required).
        write("{}", to: dir + "/stack.json")
        try expect(StackSource.loadFolder(at: dir, defaults: [:]) == nil)
    }

    test("loadFolder: valid manifest populates id/name/rootURL") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write(minimalManifest, to: dir + "/stack.json")
        guard let src = StackSource.loadFolder(at: dir, defaults: [:]) else {
            try expect(false, "expected non-nil StackSource"); return
        }
        try expectEqual(src.manifest.id, "demo")
        try expectEqual(src.manifest.name, "Demo")
        try expectEqual(src.manifest.size.h, 24)
        try expectEqual(src.rootURL.path, dir)
    }

    test("loadFolder: sourceText aggregates html/css/js/mjs contents") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write(minimalManifest, to: dir + "/stack.json")
        write("<div id='a'/>", to: dir + "/index.html")
        write(".b { color: red }", to: dir + "/index.css")
        write("const c = 1;", to: dir + "/index.js")
        write("export const d = 2;", to: dir + "/extra.mjs")
        // README.md should NOT be scanned.
        write("# ignored", to: dir + "/README.md")

        guard let src = StackSource.loadFolder(at: dir, defaults: [:]) else {
            try expect(false, "expected non-nil StackSource"); return
        }
        try expect(src.sourceText.contains("<div id='a'/>"), "html missing")
        try expect(src.sourceText.contains(".b { color: red }"), "css missing")
        try expect(src.sourceText.contains("const c = 1;"), "js missing")
        try expect(src.sourceText.contains("export const d = 2;"), "mjs missing")
        try expect(!src.sourceText.contains("# ignored"), "md leaked into sourceText")
    }

    test("loadFolder: defaults merge — manifest overrides defaults") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Manifest provides its own name; defaults' name should be ignored
        // because raw is merged INTO defaults (so manifest wins).
        write(minimalManifest, to: dir + "/stack.json")
        let defaults: [String: Any] = ["name": "FromDefaults"]
        guard let src = StackSource.loadFolder(at: dir, defaults: defaults) else {
            try expect(false, "expected non-nil StackSource"); return
        }
        try expectEqual(src.manifest.name, "Demo")
    }

    test("loadFolder: defaults fill in fields the manifest omits") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Manifest omits `name`; on its own that would fail decode. Defaults
        // supply it, the merge satisfies StackManifest decoding.
        write(#"{ "id": "demo", "size": {"h": 24}, "permissions": [] }"#,
              to: dir + "/stack.json")
        let defaults: [String: Any] = ["name": "FromDefaults"]
        guard let src = StackSource.loadFolder(at: dir, defaults: defaults) else {
            try expect(false, "expected non-nil StackSource"); return
        }
        try expectEqual(src.manifest.name, "FromDefaults")
    }
}
