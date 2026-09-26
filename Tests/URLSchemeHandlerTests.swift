import Foundation
import WebKit

// Tests for `Sources/URLSchemeHandler.swift`.
//
// StackdSchemeHandler resolves `sd://` URLs to files on disk:
//   sd://runtime/<path>     → <runtimePath>/<path>
//   sd://<stackId>/<path>   → registered rootURL for stackId/<path>
//
// `webView(_:start:)` only reads `task.request` and reports back through the
// task's didReceive / didFinish / didFailWithError calls, so a recording
// WKURLSchemeTask is enough to drive resolution, the registration table, the
// 404 path, and the response headers (including the Content-Type derived
// from the private mimeType(for:) table).

private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: HTTPURLResponse?
    private(set) var body = Data()
    private(set) var finished = false
    private(set) var failure: NSError?

    init(_ url: String) { request = URLRequest(url: URL(string: url)!) }

    func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
    func didReceive(_ data: Data) { body.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { failure = error as NSError }
}

private enum SchemeTestWebView {
    // The handler never touches the webView argument; one shared instance
    // satisfies the signature.
    static let shared = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
}

func registerURLSchemeHandlerTests() {
    /// Temp dir holding `files` (relative path → contents); removed by caller.
    func makeTree(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stackd-scheme-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    func load(_ handler: StackdSchemeHandler, _ url: String) -> RecordingSchemeTask {
        let task = RecordingSchemeTask(url)
        handler.webView(SchemeTestWebView.shared, start: task)
        return task
    }

    test("registered stack: serves the file with 200, body, and no-store/CORS headers") {
        let root = makeTree(["index.html": "<p>hi</p>"])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = StackdSchemeHandler(runtimePath: "/nonexistent")
        h.register(stackId: "demo", rootURL: root)

        let task = load(h, "sd://demo/index.html")
        try expect(task.failure == nil, "unexpected failure: \(String(describing: task.failure))")
        try expect(task.finished, "task should finish")
        try expectEqual(task.response?.statusCode, 200)
        try expectEqual(String(data: task.body, encoding: .utf8), "<p>hi</p>")
        try expectEqual(task.response?.value(forHTTPHeaderField: "Content-Length"), "9")
        try expectEqual(task.response?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
        try expectEqual(task.response?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    test("registered stack: nested paths resolve under the root") {
        let root = makeTree(["modules/nested/a.js": "export const a = 1;"])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = StackdSchemeHandler(runtimePath: "/nonexistent")
        h.register(stackId: "demo", rootURL: root)

        let task = load(h, "sd://demo/modules/nested/a.js")
        try expectEqual(String(data: task.body, encoding: .utf8), "export const a = 1;")
    }

    test("runtime host resolves against runtimePath, not the stack table") {
        let runtime = makeTree(["api.js": "export const sd = {};"])
        defer { try? FileManager.default.removeItem(at: runtime) }
        let h = StackdSchemeHandler(runtimePath: runtime.path)

        let task = load(h, "sd://runtime/api.js")
        try expectEqual(task.response?.statusCode, 200)
        try expectEqual(String(data: task.body, encoding: .utf8), "export const sd = {};")
    }

    test("unknown stack id and missing file both fail with 404, no response") {
        let root = makeTree(["index.html": "x"])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = StackdSchemeHandler(runtimePath: "/nonexistent")
        h.register(stackId: "demo", rootURL: root)

        for url in ["sd://other/index.html", "sd://demo/missing.html"] {
            let task = load(h, url)
            try expectEqual(task.failure?.code, 404, url)
            try expect(task.response == nil && !task.finished, "\(url) must not also respond")
        }
    }

    test("unregister and clearRegistrations remove the mapping") {
        let root = makeTree(["index.html": "x"])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = StackdSchemeHandler(runtimePath: "/nonexistent")

        h.register(stackId: "a", rootURL: root)
        h.unregister(stackId: "a")
        try expectEqual(load(h, "sd://a/index.html").failure?.code, 404, "after unregister")

        h.register(stackId: "a", rootURL: root)
        h.register(stackId: "b", rootURL: root)
        h.clearRegistrations()
        try expectEqual(load(h, "sd://a/index.html").failure?.code, 404, "a after clear")
        try expectEqual(load(h, "sd://b/index.html").failure?.code, 404, "b after clear")
    }

    test("re-registering an id points it at the new root") {
        let first = makeTree(["index.html": "first"])
        let second = makeTree(["index.html": "second"])
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let h = StackdSchemeHandler(runtimePath: "/nonexistent")
        h.register(stackId: "dup", rootURL: first)
        h.register(stackId: "dup", rootURL: second)
        try expectEqual(String(data: load(h, "sd://dup/index.html").body, encoding: .utf8), "second")
    }

    test("Content-Type follows the file extension (case-insensitive)") {
        let cases: [(file: String, mime: String)] = [
            ("a.html",  "text/html; charset=utf-8"),
            ("a.htm",   "text/html; charset=utf-8"),
            ("a.js",    "text/javascript; charset=utf-8"),
            ("a.mjs",   "text/javascript; charset=utf-8"),
            ("a.css",   "text/css; charset=utf-8"),
            ("a.json",  "application/json; charset=utf-8"),
            ("a.svg",   "image/svg+xml"),
            ("a.png",   "image/png"),
            ("a.jpg",   "image/jpeg"),
            ("a.JPEG",  "image/jpeg"),
            ("a.woff2", "font/woff2"),
            ("a.bin",   "application/octet-stream"),
        ]
        var files: [String: String] = [:]
        for c in cases { files[c.file] = "x" }
        let root = makeTree(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let h = StackdSchemeHandler(runtimePath: "/nonexistent")
        h.register(stackId: "mime", rootURL: root)

        for c in cases {
            let task = load(h, "sd://mime/\(c.file)")
            try expectEqual(task.response?.value(forHTTPHeaderField: "Content-Type"), c.mime, c.file)
        }
    }
}
