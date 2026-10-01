import Foundation
import JavaScriptCore

// Tests for `StackFolders` in Sources/StackHost.swift: the folder half of
// `stackd disable|enable` / sd.stacks.disable|enable. A stack is enabled
// while its folder sits in <root>/stacks/ and disabled while it sits in
// <root>/disabled/. Exercised against a throwaway root directory.
//
// NOT covered here: the live unload/load around the move (StackHost needs
// real StackWindows) — runtime-verified with `stackd disable <id>`.

private func makeRoot() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("stackd-folders-\(UUID().uuidString)")
    try fm.createDirectory(at: root.appendingPathComponent("stacks/bar"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appendingPathComponent("stacks/bar/stack.json"))
    return root
}

func registerStackFoldersTests() {
    test("StackFolders.isValidId rejects paths, dot names and empties") {
        try expect(StackFolders.isValidId("bar"))
        try expect(StackFolders.isValidId("overlay-border"))
        for bad in ["", ".", "..", ".hidden", "a/b", "../stacks", "bar@1"] {
            try expect(!StackFolders.isValidId(bad), "expected '\(bad)' to be rejected")
        }
    }

    test("StackFolders.move disables and re-enables a stack folder") {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try expectEqual(StackFolders.move(id: "bar", to: .disabled, root: root.path), nil)
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("disabled/bar/stack.json").path))
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stacks/bar").path))
        try expectEqual(StackFolders.list(.disabled, root: root.path), ["bar"])
        try expectEqual(StackFolders.move(id: "bar", to: .enabled, root: root.path), nil)
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("stacks/bar/stack.json").path))
        try expectEqual(StackFolders.list(.disabled, root: root.path), [])
    }

    test("StackFolders.move explains what's wrong instead of moving") {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try expectEqual(StackFolders.move(id: "nope", to: .disabled, root: root.path),
                        "no stack named 'nope'")
        try expectEqual(StackFolders.move(id: "bar", to: .enabled, root: root.path),
                        "'bar' is already enabled")
        try expectEqual(StackFolders.move(id: "../x", to: .disabled, root: root.path),
                        "invalid stack id '../x'")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("disabled/bar"),
                                                withIntermediateDirectories: true)
        try expectEqual(StackFolders.move(id: "bar", to: .disabled, root: root.path),
                        "can't disable 'bar': disabled/bar already exists")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("stacks/bar/stack.json").path),
                   "a refused move leaves the folder in place")
    }

    test("StackFolders.list skips files and hidden entries, sorted") {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for d in ["disabled/zeta", "disabled/alpha", "disabled/.git"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("disabled/README.md"))
        try expectEqual(StackFolders.list(.disabled, root: root.path), ["alpha", "zeta"])
        try expectEqual(StackFolders.list(.enabled, root: root.path), ["bar"])
    }

    test("sd.stacks sends list / disable / enable requests") {
        let ctx = JSHarness.context
        ctx.evaluateScript("""
        globalThis.__st = { real: window.webkit.messageHandlers.sd.postMessage, sent: [] };
        window.webkit.messageHandlers.sd.postMessage = (p) => __st.sent.push([p.type, p.id ?? null]);
        sd.stacks.list(); sd.stacks.disable("bar"); sd.stacks.enable("bar");
        window.webkit.messageHandlers.sd.postMessage = __st.real;
        """)
        try expectEqual(ctx.evaluateScript("JSON.stringify(__st.sent)")?.toString(),
                        "[[\"stacks.list\",null],[\"stacks.disable\",\"bar\"],[\"stacks.enable\",\"bar\"]]")
    }
}
