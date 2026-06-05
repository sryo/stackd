import Foundation
import CoreGraphics  // CGDirectDisplayID / CGMainDisplayID / CGRect — display routing

/// Display primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1). Three entries:
///
///   - `display.setBrightness` / `display.getBrightness` — pure `.sync(...)`
///     into `Sources/DataSources/Display.swift`. Routes between internal
///     panels (DisplayServices) and external monitors (DDC/CI via
///     IOAVService) inside `Display.setBrightness`. `displayID` of 0 or
///     missing falls back to `CGMainDisplayID()` so single-display callers
///     don't have to enumerate screens.
///
///   - `display.snapshot` — single-frame ScreenCaptureKit grab on macOS 14+,
///     CGWindowListCreateImage on 13. Async because both backends are
///     callback-driven; the closure captures `bridge` to deliver the
///     response. No per-instance state captured beyond `respond`.
///
/// No new state widening — this group only needs `respond` (already widened
/// to internal for BridgeFS / BridgeSearch).
extension Bridge {
    /// Display primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func displayPrimitives() -> [Primitive] {
        return [
            // `displayID` is the CGDirectDisplayID returned by sd.display.all.
            // When 0 / missing, falls back to CGMainDisplayID so single-display
            // callers can just pass the value without enumerating screens.
            // Routing between internal (DisplayServices) and external (DDC/CI
            // via IOAVService) happens inside Display.setBrightness.
            .sync("display.setBrightness", permission: "display", denyValue: false) { body in
                let id: CGDirectDisplayID
                if let raw = body["displayID"] as? Int, raw != 0 {
                    id = CGDirectDisplayID(raw)
                } else {
                    id = CGMainDisplayID()
                }
                return Display.setBrightness(
                    displayID: id,
                    Float((body["value"] as? Double) ?? 0))
            },
            // Mirror of setBrightness — reads back current brightness as a 0..1
            // Double or null. External monitors often nil out (DDC-read is
            // optional in the spec); built-in always returns a value.
            .sync("display.getBrightness", permission: "display", denyValue: NSNull()) { body in
                let id: CGDirectDisplayID
                if let raw = body["displayID"] as? Int, raw != 0 {
                    id = CGDirectDisplayID(raw)
                } else {
                    id = CGMainDisplayID()
                }
                return Display.brightness(of: id).map { Double($0) } ?? NSNull()
            },

            // Display snapshot — single-frame ScreenCaptureKit grab (14+) or
            // CGWindowListCreateImage on 13. Returns { dataURL, width, height }
            // or null on failure. Folded under the existing "display" permission
            // because every consumer that needs pixels already wants sd.display.all
            // to enumerate screens.
            .custom("display.snapshot", permission: "display") { bridge, body, requestId in
                let id = (body["displayID"] as? Int).map { CGDirectDisplayID($0) }
                    ?? CGMainDisplayID()
                var region: CGRect? = nil
                if let r = body["region"] as? [String: Any] {
                    region = CGRect(
                        x: (r["x"] as? Double) ?? 0,
                        y: (r["y"] as? Double) ?? 0,
                        width:  (r["w"] as? Double) ?? 0,
                        height: (r["h"] as? Double) ?? 0
                    )
                }
                let opts = DisplaySnapshot.Options(
                    displayID: id,
                    region: region,
                    format: body["format"] as? String ?? "png",
                    quality: body["quality"] as? Double ?? 0.85
                )
                DisplaySnapshot.capture(opts) { [weak bridge] result in
                    bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
                }
            },
        ]
    }
}
