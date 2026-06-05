import Foundation

/// Bonjour / mDNS primitive group — extracted from Bridge.swift as part of
/// the god-object breakup continuation (follow-up to A1). Four entries:
///
///   - `bonjour.publish` / `bonjour.publish.stop` — long-lived NWListener
///     that advertises {name, type, port} over mDNS. Returns a handle id;
///     JS wraps it as `{ id, stop() }`. macOS 15+ surfaces a Local Network
///     privacy prompt on first publish — Network.framework raises it, we
///     don't preflight.
///
///   - `bonjour.browse.start` / `bonjour.browse.stop` — long-lived
///     NWBrowser that fires per-handle channel pushes
///     ("bonjour:browse:<id>") with the full current result-set on every
///     change. JS `sd.bonjour.browse(type)` returns
///     `{ id, subscribe(fn), stop() }` that wires the same channel name
///     to the standard signal machinery.
///
/// IPC envelope's `type` key is reserved for primitive dispatch
/// ("bonjour.publish"), so the mDNS service type travels under
/// `serviceType` — matches the caffeinate.assert/assertionType workaround.
///
/// `bonjourPublishHandles`, `bonjourBrowseHandles`, and `nextBonjourId`
/// were widened from fileprivate to internal in Bridge.swift so this
/// file's `.custom` / `.syncBridge` closures can mint and release the
/// handles. Scope drain on stack unload (end of Bridge.swift) cancels
/// every surviving listener / browser.
extension Bridge {
    /// Bonjour primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func bonjourPrimitives() -> [Primitive] {
        return [
            .custom("bonjour.publish", permission: "bonjour") { bridge, body, requestId in
                // IPC envelope's `type` key is reserved for primitive dispatch
                // ("bonjour.publish"), so the service type travels under
                // `serviceType` — matches the caffeinate.assert/assertionType
                // workaround elsewhere in this file.
                let name = body["name"] as? String ?? ""
                let type = body["serviceType"] as? String ?? ""
                let port = UInt16((body["port"] as? Int) ?? 0)
                let txt  = body["txt"] as? [String: String]
                guard !name.isEmpty, !type.isEmpty, port > 0,
                      let handle = Bonjour.publish(name: name, type: type, port: port, txt: txt) else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                let id = bridge.nextBonjourId
                bridge.nextBonjourId += 1
                bridge.bonjourPublishHandles[id] = Token { handle.stop() }
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("bonjour.publish.stop", permission: "bonjour", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let t  = b.bonjourPublishHandles.removeValue(forKey: id) else { return false }
                t.cancel()
                return true
            },
            .custom("bonjour.browse.start", permission: "bonjour") { bridge, body, requestId in
                // serviceType (not `type`) for the same envelope-collision reason
                // documented on bonjour.publish above.
                let type = body["serviceType"] as? String ?? ""
                guard !type.isEmpty else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                let id = bridge.nextBonjourId
                bridge.nextBonjourId += 1
                let channel = "bonjour:browse:\(id)"
                let browser = Bonjour.Browser(type: type) { [weak bridge] entries in
                    guard let bridge = bridge else { return }
                    let json = Bridge.jsonify(entries)
                    bridge.push(channel: channel, json: json)
                }
                bridge.bonjourBrowseHandles[id] = Token { browser.stop() }
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("bonjour.browse.stop", permission: "bonjour", denyValue: false) { b, body in
                guard let id = body["id"] as? Int,
                      let t  = b.bonjourBrowseHandles.removeValue(forKey: id) else { return false }
                t.cancel()
                return true
            },
        ]
    }
}
