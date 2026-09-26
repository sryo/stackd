import WebKit

/// Routes `sd://` URLs:
///   sd://runtime/<path>     → ~/stackd/Runtime/<path>
///   sd://<stackId>/<path>   → ~/stackd/stacks/<stackId>/<path>
final class StackdSchemeHandler: NSObject, WKURLSchemeHandler {
    private let runtimePath: String
    private var stacks: [String: URL] = [:]

    init(runtimePath: String) {
        self.runtimePath = runtimePath
        super.init()
    }

    func register(stackId: String, rootURL: URL) {
        stacks[stackId] = rootURL
    }

    func unregister(stackId: String) {
        stacks.removeValue(forKey: stackId)
    }

    func clearRegistrations() {
        stacks.removeAll()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(NSError(domain: "stackd", code: 400)); return
        }
        let host = url.host ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var fileURL: URL?
        if host == "runtime" {
            fileURL = Self.contained(path, under: URL(fileURLWithPath: runtimePath))
        } else if let root = stacks[host] {
            fileURL = Self.contained(path, under: root)
        }

        guard let file = fileURL, let data = try? Data(contentsOf: file) else {
            log("404 \(url.absoluteString) → \(fileURL?.path ?? "no-mapping")")
            task.didFailWithError(NSError(domain: "stackd", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Not found: \(url.absoluteString)"
            ]))
            return
        }
        log("200 \(url.absoluteString) (\(data.count)B)")

        let mime = mimeType(for: file.pathExtension)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-store"
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// `root/path` with `..` and every symlink resolved, or nil unless the
    /// result is a descendant of the equally resolved root. `url.path` has
    /// already percent-decoded `..%2F`, so encoded traversal lands here too.
    private static func contained(_ path: String, under root: URL) -> URL? {
        guard let base = realPath(root.path),
              let file = realPath(root.appendingPathComponent(path).path) else { return nil }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard file.hasPrefix(prefix) else {
            log("403 \(path) resolves outside \(base)")
            return nil
        }
        return URL(fileURLWithPath: file)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "woff2":       return "font/woff2"
        default:            return "application/octet-stream"
        }
    }
}
