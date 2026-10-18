import AppKit
import WebKit

// Tests for StackHost's unload paths (toggle, disable): after a stack's
// last instance unloads, its sd://<id>/ scheme registration is gone, while
// an instance still loaded keeps serving.
//
// Runs a real StackHost against a throwaway root. The stacks are
// `invocable`, so their panels are created but never ordered in. The
// display list is injected so a `display: "all"` stack gets two instances
// (`<id>@0`, `<id>@1`) on a single-display machine.

private final class UnloadSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var status: Int?
    private(set) var failed = false

    init(_ url: String) { request = URLRequest(url: URL(string: url)!) }

    func didReceive(_ response: URLResponse) { status = (response as? HTTPURLResponse)?.statusCode }
    func didReceive(_ data: Data) {}
    func didFinish() {}
    func didFailWithError(_ error: Error) { failed = true }
}

private let unloadTestWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

func registerStackHostUnloadTests() {
    /// A root holding stacks/<id>/ with an invocable manifest for `display`.
    func makeRoot(id: String, display: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stackd-host-unload-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("stacks/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        {"id":"\(id)","name":"\(id)","permissions":[],"invocable":true,"display":"\(display)","size":{"w":10,"h":10}}
        """
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("stack.json"))
        try Data("<p>hi</p>".utf8).write(to: dir.appendingPathComponent("index.html"))
        return root
    }

    func serves(_ host: StackHost, _ id: String) -> Bool {
        let task = UnloadSchemeTask("sd://\(id)/index.html")
        host.schemeHandler.webView(unloadTestWebView, start: task)
        return task.status == 200 && !task.failed
    }

    func twoDisplays() throws -> [NSScreen] {
        let screen = NSScreen.screens.first
        try expect(screen != nil, "needs a display to build stack panels")
        return [screen!, screen!]
    }

    test("StackHost: unloading the last per-display instance drops the stack's scheme registration") {
        let id = "host-unload-multi"
        let root = try makeRoot(id: id, display: "all")
        defer { try? FileManager.default.removeItem(at: root) }
        let screens = try twoDisplays()
        let host = StackHost(rootPath: root.path, runtimePath: "/nonexistent", screens: { screens })

        try expectEqual(host.toggle(id: id), "enabled \(id)\n")
        try expectEqual(host.listStacks(), ["\(id)@0", "\(id)@1"])
        try expect(serves(host, id), "a loaded stack serves its files")

        _ = host.toggle(id: "\(id)@0")
        try expectEqual(host.listStacks(), ["\(id)@1"])
        try expect(serves(host, id), "the instance still loaded keeps serving")

        _ = host.toggle(id: "\(id)@1")
        try expectEqual(host.listStacks(), [])
        try expect(!serves(host, id), "no scheme registration remains once every instance unloaded")
    }

    test("StackHost: toggling a single-instance stack off drops its scheme registration") {
        let id = "host-unload-single"
        let root = try makeRoot(id: id, display: "primary")
        defer { try? FileManager.default.removeItem(at: root) }
        let screens = try twoDisplays()
        let host = StackHost(rootPath: root.path, runtimePath: "/nonexistent", screens: { screens })

        _ = host.toggle(id: id)
        try expectEqual(host.listStacks(), [id])
        try expect(serves(host, id))
        try expectEqual(host.toggle(id: id), "disabled \(id)\n")
        try expectEqual(host.listStacks(), [])
        try expect(!serves(host, id), "no scheme registration remains after unload")
    }

    test("StackHost: toggling a multi-display stack by its base id unloads every instance") {
        let id = "host-unload-base"
        let root = try makeRoot(id: id, display: "all")
        defer { try? FileManager.default.removeItem(at: root) }
        let screens = try twoDisplays()
        let host = StackHost(rootPath: root.path, runtimePath: "/nonexistent", screens: { screens })

        _ = host.toggle(id: id)
        try expectEqual(host.toggle(id: id), "disabled \(id) (was multi-display)\n")
        try expectEqual(host.listStacks(), [])
        try expect(!serves(host, id), "no scheme registration remains after unload")
    }

    test("StackHost: disabling a multi-display stack unloads every instance and its registration") {
        let id = "host-unload-disable"
        let root = try makeRoot(id: id, display: "all")
        defer { try? FileManager.default.removeItem(at: root) }
        let screens = try twoDisplays()
        let host = StackHost(rootPath: root.path, runtimePath: "/nonexistent", screens: { screens })

        _ = host.toggle(id: id)
        try expectEqual(host.disable(id: id), nil)
        try expectEqual(host.listStacks(), [])
        try expect(!serves(host, id), "no scheme registration remains after disable")
        try expectEqual(host.disabledStackIds(), [id])
    }
}
