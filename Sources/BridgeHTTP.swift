import Foundation

/// HTTP server primitive group — extracted from Bridge.swift as part of
/// the god-object breakup continuation (follow-up to A1+A4). Three entries:
///
///   - `httpserver.serve` — boots a long-running Network.framework
///     listener owned by the stack. Every request fans out to JS via
///     `__sd_http_request(serverId, requestId, {method,path,query,headers,body})`.
///     JS replies with `sd.httpserver.respond(reqId, {status,headers,body})`.
///     Stacks own all dispatch logic — route matching, CORS headers,
///     Content-Type — in JS. Loopback-only unless `bindHost === "0.0.0.0"`.
///
///   - `httpserver.stop` — cancels the Token (calls `server.stop()`) and
///     drops the id from `httpServerTokens`. Idempotent.
///
///   - `httpserver.respond` — looks up the pending NWConnection-side
///     completion closure in `pendingHttpResponses`, builds an
///     `HTTPResponse` from the body, and invokes the closure. NOT
///     permission-gated — sending a reply to an in-flight request the
///     stack already accepted is always safe. Without this exemption,
///     manifest authors would have to remember "httpserver" on the
///     respond side too, which is friction the API doesn't need.
///     `bodyEncoding: "base64"` opts into binary; anything else is UTF-8.
///
/// `httpServerTokens`, `pendingHttpResponses` and `nextHttpId` were
/// widened from fileprivate to internal in Bridge.swift so this file's
/// `.custom` / `.syncBridge` closures can mint listener handles and look
/// up pending response closures. Scope drain on stack unload stops every
/// listener owned by this stack and resolves any in-flight requests with
/// 503 so the connection's send-then-cancel path doesn't leak the
/// NWConnection.
extension Bridge {
    /// HTTP server primitives — concatenated into `Bridge.primitives`
    /// alongside the rest of the inline registrations. Pure builder; no
    /// side effects.
    static func httpServerPrimitives() -> [Primitive] {
        return [
            // ── HTTP server ─────────────────────────────────────────────────────
            // Long-running Network.framework listener owned by the stack. Every
            // request fans out to JS via __sd_http_request(serverId, requestId,
            // {method,path,query,headers,body}). JS replies with
            // sd.httpserver.respond(reqId, {status,headers,body}). Stacks own all
            // dispatch logic — route matching, CORS headers, Content-Type — in JS.
            // Loopback-only unless bindHost === "0.0.0.0". Permission: "httpserver".
            .custom("httpserver.serve", permission: "httpserver") { bridge, body, requestId in
                let port = UInt16((body["port"] as? Int) ?? 0)
                let bindHost = body["bindHost"] as? String ?? "127.0.0.1"
                let bonjourType: String? = (body["bonjour"] as? [String: Any])?["type"] as? String
                let bonjourName: String? = (body["bonjour"] as? [String: Any])?["name"] as? String

                let serverId = bridge.nextHttpId
                bridge.nextHttpId += 1
                do {
                    let server = try HTTPServer(
                        port: port,
                        bindHost: bindHost,
                        bonjourType: bonjourType,
                        bonjourName: bonjourName
                    ) { [weak bridge] req, complete in
                        guard let bridge = bridge else {
                            complete(HTTPResponse(status: 503)); return
                        }
                        DispatchQueue.main.async {
                            let reqId = bridge.nextHttpId
                            bridge.nextHttpId += 1
                            bridge.pendingHttpResponses[reqId] = complete
                            let payload: [String: Any] = [
                                "method":  req.method,
                                "path":    req.path,
                                "query":   req.query,
                                "headers": req.headers,
                                "body":    req.body
                            ]
                            let json = Bridge.jsonify(payload)
                            bridge.webView?.evaluateJavaScript(
                                "window.__sd_http_request && window.__sd_http_request(\(serverId), \(reqId), \(json));",
                                completionHandler: nil
                            )
                        }
                    }
                    server.start()
                    let token = Token { server.stop() }
                    bridge.httpServerTokens[serverId] = token
                    bridge.respond(requestId: requestId, value: serverId)
                } catch {
                    FileHandle.standardError.write(Data("stackd: httpserver bind failed on :\(port) — \(error)\n".utf8))
                    bridge.respond(requestId: requestId, value: NSNull())
                }
            },
            .syncBridge("httpserver.stop", permission: "httpserver", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let token = b.httpServerTokens.removeValue(forKey: id) else { return false }
                token.cancel()
                return true
            },
            // No permission gate on respond — sending a reply to an in-flight
            // request the stack already accepted is always safe. Without this
            // exemption, manifest authors would have to remember "httpserver"
            // on the respond side too, which is friction the API doesn't need.
            .syncBridge("httpserver.respond", permission: nil, denyValue: false) { b, body in
                guard let reqId = body["reqId"] as? Int,
                      let complete = b.pendingHttpResponses.removeValue(forKey: reqId) else {
                    return false
                }
                var response = HTTPResponse()
                response.status  = body["status"] as? Int ?? 200
                response.headers = body["headers"] as? [String: String] ?? [:]
                let raw = body["body"] as? String ?? ""
                // Stacks opt into binary by passing bodyEncoding: "base64" — typical
                // pairing is sd.fs.read(path, { encoding: "base64" }) → forward the
                // string straight through. Anything else (or missing) treats body as
                // a UTF-8 string, matching the original String-only contract.
                if (body["bodyEncoding"] as? String) == "base64",
                   let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]) {
                    response.bodyBytes = data
                } else {
                    response.body = raw
                }
                complete(response)
                return true
            },
        ]
    }
}
