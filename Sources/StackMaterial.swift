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

/// Outer shape of a stack window's material backing.
///
///   - `.rect`     — uses the manifest `cornerRadius` (default).
///   - `.capsule`  — cornerRadius = min(width, height) / 2 → horizontal pill
///                   when w > h, vertical pill when h > w, circle when w == h.
///                   Ignores manifest `cornerRadius`. Computed at window-init
///                   time only — doesn't track live resizes (v1 limitation).
///
/// Mirrors SwiftUI's `Capsule`/`RoundedRectangle` shape distinction, exposed
/// as a manifest primitive so stacks can opt into pill-shaped glass without
/// computing radii themselves.
enum StackShape: String {
    case rect
    case capsule

    static func parse(_ raw: String?) -> StackShape {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "capsule": return .capsule
        case "rect", "rectangle", "rounded", nil, "": return .rect
        default:
            log("stack shape: unknown value '\(raw ?? "")' — falling back to rect")
            return .rect
        }
    }

    /// Resolve the OUTER cornerRadius given the window's frame size and any
    /// manifest-supplied radius. For `.capsule` the manifest radius is
    /// ignored — capsule shape is defined by its frame.
    func outerRadius(frame: CGSize, manifestRadius: Double?) -> Double {
        switch self {
        case .rect:
            return max(0, manifestRadius ?? 0)
        case .capsule:
            return Double(min(frame.width, frame.height)) / 2.0
        }
    }
}

/// Inner inset between the material edge and the WebView, in points.
///
/// Enables concentric corners: when the WebView is inset by P inside a
/// material with outer cornerRadius R, the WebView's own cornerRadius
/// becomes `max(0, R - P)` so the inner curve is concentric with the outer
/// (parallel arcs sharing a center). Mirrors SwiftUI's
/// `RoundedRectangularShapeCorners.concentric` / `ConcentricRectangle`.
///
/// Apple's HIG guidance: when the inset exceeds the outer radius, the
/// inner corners collapse to 0 (sharp). Matches the SwiftUI implementation.
enum StackPadding {
    static func parse(_ raw: Double?) -> Double {
        guard let raw = raw else { return 0 }
        return max(0, raw)
    }

    /// Resolve the EFFECTIVE padding for a stack given the manifest value,
    /// material, and outer cornerRadius.
    ///
    ///   - Explicit manifest value (even 0) → use it verbatim (clamped ≥ 0).
    ///   - Missing/nil on a glass material with cornerRadius > 0 →
    ///     auto-default to `cornerRadius / 2`. This keeps the glass rim
    ///     visible without each stack having to hand-tune it: the rim
    ///     thickness equals the inner WebView's cornerRadius, producing a
    ///     pleasing geometric symmetry (padding == innerRadius).
    ///   - Missing/nil on non-glass or radius-less → 0 (no inset).
    ///
    /// Tying the default to cornerRadius (vs a fixed constant) means stacks
    /// that opt into bigger corners automatically get proportionally bigger
    /// rims — matches the "stack composes, daemon ships primitives" rule.
    static func effectivePadding(manifest: Double?, material: StackMaterial, cornerRadius: Double?) -> Double {
        if let m = manifest { return max(0, m) }
        if case .glass = material, let r = cornerRadius, r > 0 {
            return r / 2.0
        }
        return 0
    }

    /// Pure concentric inner-radius formula. `padding ≥ outer` → 0 (collapses
    /// to a sharp corner, matching SwiftUI's behavior).
    static func concentricInnerRadius(outer: Double, padding: Double) -> Double {
        return max(0, outer - padding)
    }
}

/// Where the WebView should be attached relative to the backing material.
///
/// Glass and vibrancy require different view hierarchies — this enum lifts the
/// decision out of `StackWindow.init` so it can be unit-tested without
/// instantiating a real panel.
///
///   - `directContent`     — no material, no radius. WebView is the panel's
///                           contentView directly.
///   - `siblingInContainer` — vibrancy (or pre-Tahoe `.glass` fallback, or
///                           `.none` with a rounded corner). Effect view sits
///                           behind the WebView as a sibling inside a plain
///                           NSView container. `blendingMode = .behindWindow`
///                           on NSVisualEffectView renders desktop blur through
///                           the transparent WebView chain.
///   - `embeddedInGlass`    — Liquid Glass on macOS 26+. WebView is set as the
///                           NSGlassEffectView's `contentView`. The SDK header
///                           is explicit: glass effects only render correctly
///                           when content is embedded via `contentView` —
///                           arbitrary sibling subviews are documented as
///                           undefined z-order. Without this, glass renders as
///                           a flat plate underneath the WebView and the
///                           refraction / specular highlight never fires.
enum MaterialAttachment: Equatable {
    case directContent
    case siblingInContainer
    case embeddedInGlass

    /// Pure decision: given the material, an optional corner radius, and
    /// whether NSGlassEffectView is available (i.e. macOS 26+), how should the
    /// WebView be attached?
    static func mode(
        material: StackMaterial,
        cornerRadius: Double?,
        supportsGlass: Bool
    ) -> MaterialAttachment {
        if case .none = material, (cornerRadius ?? 0) <= 0 {
            return .directContent
        }
        if case .glass = material, supportsGlass {
            return .embeddedInGlass
        }
        return .siblingInContainer
    }
}
