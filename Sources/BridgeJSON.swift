import AppKit

/// JSON / payload-encoding helpers — extracted from Bridge.swift in the A8
/// breakup round. Pure functions only: `jsonify` / `jsString` (JS-safe
/// serialization), `parseIconSpec` / `parseStatusItemSpec` (menubar body
/// parsers), and `screenInfo` / `rect` (the display payload shared by the
/// per-instance `window.__sd_screen` inject and sd.display consumers).
/// Everything stays `static` on `Bridge` so call sites keep working.
extension Bridge {
    static func screenInfo(screen: NSScreen, index: Int) -> [String: Any] {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let uuid: String = {
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
            return CFUUIDCreateString(nil, cf) as String? ?? ""
        }()
        // Notch geometry: NSScreen exposes auxiliaryTopLeftArea /
        // auxiliaryTopRightArea on notched displays (macOS 12+). Width of
        // the notch = rightArea.origin.x - leftArea.size.width. On
        // external/non-notched displays both are nil; we return null so
        // stacks can branch on it.
        var notchPayload: Any = NSNull()
        if #available(macOS 12.0, *) {
            if let lArea = screen.auxiliaryTopLeftArea,
               let rArea = screen.auxiliaryTopRightArea,
               lArea.width > 0, rArea.origin.x > lArea.width {
                notchPayload = [
                    "leftWidth":  Int(lArea.width),
                    "rightX":     Int(rArea.origin.x),
                    "width":      Int(rArea.origin.x - lArea.width),
                    "safeAreaTop": Int(screen.safeAreaInsets.top)
                ] as [String: Any]
            }
        }
        // Top-left, matching sd.display.all and every other xy in sd.*.
        let cgFrame = CGDisplayBounds(id)
        let nsFrame = screen.frame, nsVisible = screen.visibleFrame
        let topInset    = max(0, nsFrame.maxY - nsVisible.maxY)
        let bottomInset = max(0, nsVisible.minY - nsFrame.minY)
        let leftInset   = max(0, nsVisible.minX - nsFrame.minX)
        let rightInset  = max(0, nsFrame.maxX - nsVisible.maxX)
        let cgVisible = CGRect(
            x: cgFrame.minX + leftInset,
            y: cgFrame.minY + topInset,
            width:  max(0, cgFrame.width  - leftInset - rightInset),
            height: max(0, cgFrame.height - topInset  - bottomInset)
        )
        return [
            "uuid":         uuid,
            "displayID":    Int(id),
            "index":        index,
            "frame":        rect(cgFrame),
            "visibleFrame": rect(cgVisible),
            "notch":        notchPayload
        ]
    }

    private static func rect(_ r: CGRect) -> [String: Int] {
        ["x": Int(r.origin.x), "y": Int(r.origin.y),
         "w": Int(r.size.width), "h": Int(r.size.height)]
    }

    /// Escape an arbitrary string into a JS string literal. JSONSerialization
    /// handles the corner cases (quotes, backslashes, control chars) that
    /// naive replacement would miss.
    ///
    /// Widened from fileprivate to internal so Bridge.swift's `fireGlobal` /
    /// `dispatchMenubarEvent` can keep calling it after the move to
    /// BridgeJSON.swift.
    static func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
           let out = String(data: data, encoding: .utf8) {
            return out
        }
        return "\"\""
    }

    static func jsonify(_ obj: Any) -> String {
        // .fragmentsAllowed lets us serialize bare scalars (Bool/Int/String) at
        // the top level — required for imperative API responses like
        // setVolume → true, defaults.read → "value".
        // .sortedKeys guarantees deterministic key order so the channel
        // dedupe (string-compare against lastState[channel]) doesn't
        // false-mismatch when two code paths build the same dict in
        // different insertion orders (e.g. MediaRemote vs scripted-fallback
        // building the media snapshot).
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    /// Widened from fileprivate to internal so BridgeMenubar.swift can
    /// build IconSpec values for menubar.item.setIcon.
    static func parseIconSpec(_ dict: [String: Any]) -> IconSpec {
        IconSpec(
            sfSymbol:  dict["sfSymbol"]  as? String,
            pngBase64: dict["pngBase64"] as? String,
            template:  dict["template"]  as? Bool ?? true
        )
    }

    /// Widened from fileprivate to internal so BridgeMenubar.swift can
    /// build StatusItemSpec values for menubar.addItem.
    static func parseStatusItemSpec(_ body: [String: Any]) -> StatusItemSpec {
        var spec = StatusItemSpec()
        if let icon = body["icon"] as? [String: Any] { spec.icon = parseIconSpec(icon) }
        spec.title   = body["title"]   as? String
        spec.menu    = body["menu"]    as? [[String: Any]]
        spec.tooltip = body["tooltip"] as? String
        return spec
    }
}
