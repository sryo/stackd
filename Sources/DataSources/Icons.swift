import AppKit

// Cheap NSImage → PNG → base64 data-URL. Stacks use these in `<img src="">`
// directly, no extra fetch. For a launcher with 8 visible result rows the
// per-frame cost is one `icon(forFile:)` per row at startup; thereafter the
// browser caches the data URL. Future optimization: serve via sd://icon/<id>
// and skip the base64 round-trip — only worth it once a stack actually hurts.

enum Icons {
    static func forApp(bundleId: String, size: Int) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return dataURL(forIconAt: url, size: size)
    }

    static func forFile(path: String, size: Int) -> String? {
        let p = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: p) else { return nil }
        return dataURL(forIconAt: URL(fileURLWithPath: p), size: size)
    }

    private static func dataURL(forIconAt url: URL, size: Int) -> String? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        // Re-rasterize at the requested point size — Apple's icon may be a
        // multi-rep TIFF and we want a single PNG sized to taste.
        let target = NSImage(size: NSSize(width: size, height: size))
        target.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                  from: .zero, operation: .copy, fraction: 1.0)
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
