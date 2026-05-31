import Foundation
import Network

// Long-running HTTP server via Network.framework. NWListener handles TCP +
// TLS for free; HTTP/1.1 parsing lives in this file because the surface we
// need (request line, headers, body up to Content-Length) is ~80 lines and
// vendoring a third-party server would dwarf the daemon's only-system-deps
// posture.
//
// Loopback-only by default. bindHost: "0.0.0.0" opts into LAN exposure and
// is the only knob that flips the listener off 127.0.0.1. Bonjour
// advertisement is optional and follows the same shape as the rest of the
// daemon's network-discovery code (NWListener.service).
//
// Static assets ride on assetsDir; routes are matched first, then a path
// inside assetsDir is served verbatim. No directory traversal — paths are
// resolved against assetsDir and rejected if the resolved file falls outside.

enum HTTPServerStore {
    private static var lock = NSLock()
    private static var servers: [Int: HTTPServer] = [:]
    private static var nextId: Int = 1

    static func register(_ server: HTTPServer) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId; nextId += 1
        servers[id] = server
        return id
    }

    static func unregister(_ id: Int) -> HTTPServer? {
        lock.lock(); defer { lock.unlock() }
        return servers.removeValue(forKey: id)
    }

    static func get(_ id: Int) -> HTTPServer? {
        lock.lock(); defer { lock.unlock() }
        return servers[id]
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: String
}

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: String = ""
}

final class HTTPServer {
    let port: UInt16
    let bindHost: String
    private let assetsDir: String?
    private let routes: [(method: String, path: String)]
    private let onRequest: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "stackd.httpserver")

    init(port: UInt16,
         bindHost: String,
         assetsDir: String?,
         routes: [(String, String)],
         bonjourType: String?,
         bonjourName: String?,
         onRequest: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void) throws {
        self.port = port
        self.bindHost = bindHost
        self.assetsDir = assetsDir
        self.routes = routes
        self.onRequest = onRequest

        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        if let t = bonjourType, let n = bonjourName {
            listener.service = NWListener.Service(name: n, type: t)
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        self.listener = listener
    }

    func start() {
        // Network.framework binds to 0.0.0.0 by default; for loopback-only we
        // gate per-connection in handle() rather than fiddling with
        // NWParameters' RequiredInterface, which doesn't accept "lo0" cleanly.
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection conn: NWConnection) {
        // bindHost == "0.0.0.0" means LAN-allowed; anything else (default
        // "127.0.0.1") drops non-loopback peers without ever reading the
        // request. NWConnection exposes the remote endpoint pre-handshake.
        if bindHost != "0.0.0.0" {
            if let endpoint = conn.endpoint as NWEndpoint?, !isLoopback(endpoint) {
                conn.cancel(); return
            }
        }
        conn.start(queue: queue)
        receive(connection: conn, buffer: Data())
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        if case let .hostPort(host, _) = endpoint {
            switch host {
            case .ipv4(let addr): return addr.rawValue.first == 127
            case .ipv6(let addr):
                let bytes = addr.rawValue
                // ::1 is 15 zero bytes followed by 0x01.
                return bytes.dropLast() == Data(repeating: 0, count: 15) && bytes.last == 0x01
            case .name(let n, _): return n == "localhost"
            @unknown default:     return false
            }
        }
        return false
    }

    // Naive incremental read until either the request line + headers + body
    // are complete, or 1 MiB cap is hit. Keep-alive is not implemented —
    // every connection serves one request and closes.
    private func receive(connection conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                _ = error; conn.cancel(); return
            }
            var buf = buffer
            if let data = data { buf.append(data) }
            if buf.count > 1_048_576 { self.send(conn: conn, response: HTTPResponse(status: 413)); return }

            if let req = self.tryParse(buf) {
                self.dispatch(connection: conn, request: req)
            } else if isComplete {
                conn.cancel()
            } else {
                self.receive(connection: conn, buffer: buf)
            }
        }
    }

    private func tryParse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = data.subdata(in: 0..<sep.lowerBound)
        guard let headStr = String(data: head, encoding: .utf8) else { return nil }
        let lines = headStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0].uppercased()
        let target = parts[1]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                let k = String(line[..<i]).trimmingCharacters(in: .whitespaces).lowercased()
                let v = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        let bodyExpected = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        let available = data.count - bodyStart
        if available < bodyExpected { return nil }
        let bodyData = data.subdata(in: bodyStart..<(bodyStart + bodyExpected))
        let body = String(data: bodyData, encoding: .utf8) ?? ""
        let (path, query) = splitQuery(target)
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func splitQuery(_ target: String) -> (String, [String: String]) {
        guard let qIdx = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<qIdx])
        let qstr = String(target[target.index(after: qIdx)...])
        var dict: [String: String] = [:]
        for pair in qstr.components(separatedBy: "&") where !pair.isEmpty {
            let kv = pair.components(separatedBy: "=")
            let k = kv[0].removingPercentEncoding ?? kv[0]
            let v = (kv.count > 1 ? kv[1] : "").removingPercentEncoding ?? ""
            dict[k] = v
        }
        return (path, dict)
    }

    private func dispatch(connection conn: NWConnection, request req: HTTPRequest) {
        // Routes win first; on miss, fall through to assetsDir; on miss there,
        // 404. Method+path exact match (no patterns yet — callers can branch
        // on req.path inside their handler if they want prefix matching).
        let match = routes.first(where: { r in
            (r.method == "*" || r.method == req.method) && r.path == req.path
        })
        if match != nil {
            onRequest(req) { [weak self] response in
                self?.send(conn: conn, response: response)
            }
            return
        }
        if let dir = assetsDir, let asset = resolveAsset(dir: dir, path: req.path) {
            send(conn: conn, response: asset)
            return
        }
        send(conn: conn, response: HTTPResponse(status: 404, headers: [:], body: "not found"))
    }

    private func resolveAsset(dir: String, path: String) -> HTTPResponse? {
        let expanded = (dir as NSString).expandingTildeInPath
        let rel = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        let candidate = URL(fileURLWithPath: expanded).appendingPathComponent(rel).standardized
        let root = URL(fileURLWithPath: expanded).standardized
        guard candidate.path.hasPrefix(root.path) else { return nil }
        guard let data = try? Data(contentsOf: candidate),
              let body = String(data: data, encoding: .utf8) ?? String(data: Data([0]), encoding: .utf8) else {
            return nil
        }
        _ = body
        let mime = HTTPServer.mimeType(for: candidate.pathExtension)
        var headers = ["Content-Type": mime, "Content-Length": "\(data.count)"]
        // Allow JS-side fetch from anywhere on the LAN we already chose to listen on.
        headers["Access-Control-Allow-Origin"] = "*"
        return HTTPResponse(status: 200, headers: headers, body: String(data: data, encoding: .utf8) ?? "")
    }

    private func send(conn: NWConnection, response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(HTTPServer.reasonPhrase(response.status))\r\n"
        var headers = response.headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "text/plain; charset=utf-8" }
        let bodyData = response.body.data(using: .utf8) ?? Data()
        headers["Content-Length"] = "\(bodyData.count)"
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = head.data(using: .utf8) ?? Data()
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm":  return "text/html; charset=utf-8"
        case "js", "mjs":    return "text/javascript; charset=utf-8"
        case "css":          return "text/css; charset=utf-8"
        case "json":         return "application/json; charset=utf-8"
        case "svg":          return "image/svg+xml"
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "gif":          return "image/gif"
        case "woff2":        return "font/woff2"
        case "txt":          return "text/plain; charset=utf-8"
        default:             return "application/octet-stream"
        }
    }
}
