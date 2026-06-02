import AppKit

/// Unified material model for stack windows.
///
/// Manifest accepts (`material` field, case-insensitive on the kind):
///   - missing / null / `"none"`              → `.none`
///   - `"vibrancy.<key>"` (sidebar, hud,       → `.vibrancy(<NSVisualEffectView.Material>)`
///        popover, menu, titlebar, sheet,
///        window, header, selection)
///   - `"glass"`                              → `.glass(.regular)`
///   - `"glass.clear"`                        → `.glass(.clear)`
///   - `"glass.tinted(#RRGGBB)"`              → `.glass(.tinted(NSColor))`
///   - Legacy bare aliases (`"sidebar"`,       → `.vibrancy(<material>)` — preserved so
///     `"hud"`, `"popover"`, `"menu"`,            existing stacks continue to work without
///     `"titlebar"`, `"sheet"`, `"window"`,       manifest edits.
///     `"header"`, `"selection"`)
///   - Unknown strings / bad hex              → `.none` (warning logged, never crash)
///
/// Glass is the macOS 26 Tahoe "Liquid Glass" surface (NSGlassEffectView). On
/// earlier OSes the StackWindow factory falls back to `.hudWindow` vibrancy.
///
/// `cornerRadius` lives on the manifest as a SIBLING field, not inside the
/// enum — it applies regardless of material (transparent windows can also
/// round their WebView corners).
enum StackMaterial: Equatable {
    case none
    case vibrancy(NSVisualEffectView.Material)
    case glass(GlassVariant)

    enum GlassVariant: Equatable {
        case regular
        case clear
        case tinted(NSColor)

        static func == (lhs: GlassVariant, rhs: GlassVariant) -> Bool {
            switch (lhs, rhs) {
            case (.regular, .regular): return true
            case (.clear, .clear):     return true
            case (.tinted(let a), .tinted(let b)):
                // Compare via sRGB components so we don't depend on NSColor's
                // colorSpaceName equality (a `colorWithName:` round-trip changes
                // representation but not the visible color).
                let ca = a.usingColorSpace(.sRGB) ?? a
                let cb = b.usingColorSpace(.sRGB) ?? b
                return ca.redComponent   == cb.redComponent
                    && ca.greenComponent == cb.greenComponent
                    && ca.blueComponent  == cb.blueComponent
                    && ca.alphaComponent == cb.alphaComponent
            default: return false
            }
        }
    }

    /// Parse a manifest string into a `StackMaterial`. Nil / unknown → `.none`.
    static func parse(_ raw: String?) -> StackMaterial {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .none
        }
        let lower = raw.lowercased()
        if lower == "none" { return .none }

        // Vibrancy: prefer the explicit `vibrancy.<key>` form, fall back to
        // legacy bare aliases for backwards compat.
        if lower.hasPrefix("vibrancy.") {
            let key = String(lower.dropFirst("vibrancy.".count))
            if let m = vibrancyMaterial(forKey: key) { return .vibrancy(m) }
            log("stack material: unknown vibrancy key '\(key)' — falling back to none")
            return .none
        }
        if let m = vibrancyMaterial(forKey: lower) { return .vibrancy(m) }

        // Glass family.
        if lower == "glass"       { return .glass(.regular) }
        if lower == "glass.clear" { return .glass(.clear) }
        if lower.hasPrefix("glass.tinted(") && lower.hasSuffix(")") {
            let inner = String(lower.dropFirst("glass.tinted(".count).dropLast())
            if let color = parseHexColor(inner) {
                return .glass(.tinted(color))
            }
            log("stack material: bad hex in glass.tinted('\(inner)') — falling back to none")
            return .none
        }

        log("stack material: unknown value '\(raw)' — falling back to none")
        return .none
    }

    /// Map a legacy / explicit vibrancy key to NSVisualEffectView.Material.
    /// nil for unknown keys.
    private static func vibrancyMaterial(forKey key: String) -> NSVisualEffectView.Material? {
        switch key {
        case "sidebar":   return .sidebar
        case "hud":       return .hudWindow
        case "popover":   return .popover
        case "menu":      return .menu
        case "titlebar":  return .titlebar
        case "sheet":     return .sheet
        case "window":    return .windowBackground
        case "header":    return .headerView
        case "selection": return .selection
        default:          return nil
        }
    }

    /// Parse `#RRGGBB` or `#RRGGBBAA` into an sRGB NSColor. nil on bad input.
    private static func parseHexColor(_ s: String) -> NSColor? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8,
              hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if hex.count == 6 {
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8)  & 0xFF) / 255.0
            b = CGFloat(value         & 0xFF) / 255.0
            a = 1.0
        } else {
            r = CGFloat((value >> 24) & 0xFF) / 255.0
            g = CGFloat((value >> 16) & 0xFF) / 255.0
            b = CGFloat((value >> 8)  & 0xFF) / 255.0
            a = CGFloat(value         & 0xFF) / 255.0
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Parse a manifest cornerRadius value. Accepts any numeric (Int/Double),
/// nil/missing returns nil, negatives are clamped to 0.
///
/// Lives as a free helper rather than a property of `StackMaterial` because
/// corner radius applies regardless of material (transparent windows can also
/// round their WebView corners).
enum StackCornerRadius {
    static func parse(_ raw: Double?) -> Double? {
        guard let raw = raw else { return nil }
        return max(0, raw)
    }
}
