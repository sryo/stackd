import WebKit

/// Routes `sd://` URLs:
///   sd://runtime/<path>     → ~/stackd/Runtime/<path>
///   sd://<stackId>/<path>   → ~/stackd/stacks/<stackId>/<path> (folder format)
///   sd://<stackId>/index.html → in-memory body (single-file .stack format)
final class StackdSchemeHandler: NSObject, WKURLSchemeHandler {
    private let runtimePath: String
    private var stacks: [String: URL] = [:]
    // .stack files are body-only by design — everything past index.html
    // 404s. Fonts/images/extra JS belong in the folder format.
    private var inlineBodies: [String: String] = [:]

    init(runtimePath: String) {
        self.runtimePath = runtimePath
        super.init()
    }

    func register(stackId: String, rootURL: URL) {
        stacks[stackId] = rootURL
    }

    /// Register an in-memory body for a `.stack`-format stack. Drops any
    /// folder registration for the same id so reloads can flip formats.
    func registerInline(stackId: String, body: String) {
        stacks.removeValue(forKey: stackId)
        inlineBodies[stackId] = body
    }

    func unregister(stackId: String) {
        stacks.removeValue(forKey: stackId)
        inlineBodies.removeValue(forKey: stackId)
    }

    func clearRegistrations() {
        stacks.removeAll()
        inlineBodies.removeAll()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(NSError(domain: "stackd", code: 400)); return
        }
        let host = url.host ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Inline (.stack) bodies short-circuit the file lookup; only
        // index.html is served from memory, the rest 404s.
        if let body = inlineBodies[host], path == "index.html" {
            let data = Data(body.utf8)
            FileHandle.standardError.write(Data("stackd: 200 \(url.absoluteString) (\(data.count)B, inline)\n".utf8))
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Length": "\(data.count)",
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "no-store"
                ]
            )!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
            return
        }

        var fileURL: URL?
        if host == "runtime" {
            fileURL = URL(fileURLWithPath: runtimePath).appendingPathComponent(path)
        } else if let root = stacks[host] {
            fileURL = root.appendingPathComponent(path)
        }

        guard let file = fileURL, let data = try? Data(contentsOf: file) else {
            FileHandle.standardError.write(Data("stackd: 404 \(url.absoluteString) → \(fileURL?.path ?? "no-mapping")\n".utf8))
            task.didFailWithError(NSError(domain: "stackd", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Not found: \(url.absoluteString)"
            ]))
            return
        }
        FileHandle.standardError.write(Data("stackd: 200 \(url.absoluteString) (\(data.count)B)\n".utf8))

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
