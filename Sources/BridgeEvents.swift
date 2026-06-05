import Foundation

/// Events primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1+A4+A5). Five entries
/// covering the JS-driven CGEvent synthesis + cursor-rect gate surface:
///
///   - `events.type` / `events.key` / `events.scroll` / `events.click` —
///     CGEvent synthesis via the `EventsSynth` data source. All Bool
///     side-effect ops, deny → false. Each takes raw JS-style values
///     (string, key spec, deltas, coords) and posts a CGEvent at the HID
///     event tap. Permission: "events" — coarse gate (any synth means
///     "this stack can act like a user"). Cursor warp without a click
///     lives under a separate "cursor" permission (`sd.cursor.*`,
///     remains inline in Bridge.swift).
///
///   - `events.setTapRects` — runtime cursor-rect gate for a consumer
///     eventtap declared in this stack's manifest. Body shape:
///     `{ callback, rects: [{x,y,w,h}, …] | null }`. null clears the
///     gate; empty array suppresses (consumer never matches without
///     unregistering); populated array filters to "consume only when
///     cursor falls in any rect". Returns false when the callback name
///     isn't a consumer this stack registered (defensive — silent
///     mis-keying would otherwise hide a typo behind a no-op). Reads
///     `bridge.stackId` to scope the EventTapRegistry key.
///
/// NOTE: only the runtime API moved here. The manifest-driven eventtap
/// registration in `start(manifest:)` — which builds the predicate,
/// installs the EventTapRegistry consumer / observer, and routes the
/// callback through `fireEventTap` — stays in Bridge.swift. Same
/// separation as static manifest hotkeys vs `sd.hotkey.bind` and
/// manifest menubar items vs `sd.menubar.addItem`.
extension Bridge {
    /// Events primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func eventsPrimitives() -> [Primitive] {
        return [
            // Event synthesis — Bool side-effect ops, deny → false.
            .sync("events.type", permission: "events", denyValue: false) { body in
                EventsSynth.type(body["value"] as? String ?? ""); return true
            },
            .sync("events.key", permission: "events", denyValue: false) { body in
                EventsSynth.key(body["spec"] as? String ?? "")
            },
            .sync("events.scroll", permission: "events", denyValue: false) { body in
                EventsSynth.scroll(
                    dx: Int32(body["dx"] as? Int ?? 0),
                    dy: Int32(body["dy"] as? Int ?? 0))
            },
            .sync("events.click", permission: "events", denyValue: false) { body in
                EventsSynth.click(
                    x: body["x"] as? Double ?? 0,
                    y: body["y"] as? Double ?? 0,
                    button: body["button"] as? String ?? "left")
            },
            // Update the runtime cursor-rect gate for a consumer eventtap declared
            // in this stack's manifest (`callback` matches the eventtap entry's
            // `callback`). Body shape:
            //   { callback: "snapshotsLeftClick",
            //     rects: [{x,y,w,h}, ...] | null }
            // null → clear gate (consume on predicate alone — original behavior).
            // empty [] → empty gate (consumer never matches; suppresses without
            //   unregistering).
            // populated → consume only when cursor falls in any rect (top-left
            //   origin global screen coords, same space as sd.windows.byId.frame).
            // Returns true on accept, false when the callback name isn't a
            // consumer this stack registered (defensive — silent mis-keying
            // would otherwise hide a typo behind a no-op).
            .syncBridge("events.setTapRects", permission: "events", denyValue: false) { bridge, body in
                guard let callback = body["callback"] as? String, !callback.isEmpty else { return false }
                let key = "\(bridge.stackId):\(callback)"
                if body["rects"] is NSNull || body["rects"] == nil {
                    EventTapRegistry.shared.setConsumerRects(key: key, rects: nil)
                    return true
                }
                guard let arr = body["rects"] as? [[String: Any]] else { return false }
                let rects: [CGRect] = arr.map { d in
                    CGRect(
                        x: (d["x"] as? Double) ?? Double((d["x"] as? Int) ?? 0),
                        y: (d["y"] as? Double) ?? Double((d["y"] as? Int) ?? 0),
                        width:  (d["w"] as? Double) ?? Double((d["w"] as? Int) ?? 0),
                        height: (d["h"] as? Double) ?? Double((d["h"] as? Int) ?? 0)
                    )
                }
                EventTapRegistry.shared.setConsumerRects(key: key, rects: rects)
                return true
            },
        ]
    }
}
