import AppKit

// SF Symbol → template PNG → base64 data-URL, for stacks that render in a
// WKWebView (the bar, HUDs) and can't reach SF Symbols the way a native
// NSButton can (Menubar.swift's IconSpec.sfSymbol path). Mirrors the
// Icons.dataURL rasterize tail in Apps.swift; the difference is the source
// image (a configured system symbol, drawn as a template so its alpha shape
// can be used as a CSS mask and tinted by the consumer's currentColor).
enum Symbols {
    // Rendered at 3× into the bitmap so it stays crisp on Retina; the
    // returned width/height are logical points carrying the symbol's natural
    // aspect (SF Symbols are rarely square) so the consumer can size the
    // element without distortion. nil when the symbol name doesn't resolve.
    static func render(name: String, pointSize: Int, weight: String, scale: String) -> [String: Any]? {
        guard !name.isEmpty,
              var img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }

        let fontWeight: NSFont.Weight = [
            "ultralight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular,
            "medium": .medium, "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black
        ][weight] ?? .regular
        let symbolScale: NSImage.SymbolScale = [
            "small": .small, "medium": .medium, "large": .large
        ][scale] ?? .medium

        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(pointSize),
                                                 weight: fontWeight, scale: symbolScale)
        if let configured = img.withSymbolConfiguration(config) { img = configured }
        img.isTemplate = true

        let pts = img.size
        guard pts.width > 0, pts.height > 0 else { return nil }
        let px = NSSize(width: pts.width * 3, height: pts.height * 3)

        let target = NSImage(size: px)
        target.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: px), from: .zero, operation: .sourceOver, fraction: 1.0)
        target.unlockFocus()

        guard let tiff = target.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return nil }
        return [
            "dataURL": "data:image/png;base64," + png.base64EncodedString(),
            "width":   Int(pts.width.rounded()),
            "height":  Int(pts.height.rounded())
        ]
    }
}
