import AppKit
import Foundation

/// Tests for the unified material model (`StackMaterial.parse` +
/// `StackCornerRadius.parse`), `StackShape`, `StackPadding` and the
/// `MaterialAttachment` view-hierarchy decision. All pure — no AppKit state
/// touched beyond constructing `NSVisualEffectView.Material` / `NSColor`
/// values. The installation side (NSGlassEffectView vs NSVisualEffectView)
/// is impure and stays untested here.
func registerMaterialTests() {

    // MARK: StackMaterial.parse

    test("material: every vibrancy key decodes in both the bare and the vibrancy.* form") {
        let keys: [(String, NSVisualEffectView.Material)] = [
            ("sidebar", .sidebar), ("hud", .hudWindow), ("popover", .popover),
            ("menu", .menu), ("titlebar", .titlebar), ("sheet", .sheet),
            ("window", .windowBackground), ("header", .headerView), ("selection", .selection),
        ]
        for (key, material) in keys {
            try expectEqual(StackMaterial.parse(key), .vibrancy(material), key)
            try expectEqual(StackMaterial.parse("vibrancy.\(key)"), .vibrancy(material), "vibrancy.\(key)")
        }
    }

    test("material: glass and glass.clear decode") {
        try expectEqual(StackMaterial.parse("glass"), .glass(.regular))
        try expectEqual(StackMaterial.parse("glass.clear"), .glass(.clear))
    }

    test("material: glass.tinted decodes #RRGGBB, #RRGGBBAA, uppercase hex and a missing #") {
        let orange = NSColor(srgbRed: 1.0, green: 136/255.0, blue: 0.0, alpha: 1.0)
        try expectEqual(StackMaterial.parse("glass.tinted(#ff8800)"), .glass(.tinted(orange)))
        try expectEqual(StackMaterial.parse("glass.tinted(#FF8800)"), .glass(.tinted(orange)))
        try expectEqual(StackMaterial.parse("glass.tinted(ff8800)"), .glass(.tinted(orange)))
        let halfGreen = NSColor(srgbRed: 0.0, green: 1.0, blue: 0.0, alpha: 128/255.0)
        try expectEqual(StackMaterial.parse("glass.tinted(#00ff0080)"), .glass(.tinted(halfGreen)))
        // Equality compares the color, not just the variant.
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        try expect(StackMaterial.parse("glass.tinted(#ff8800)") != .glass(.tinted(red)),
                   "different tints must not compare equal")
        try expect(StackMaterial.parse("glass.tinted(#ff8800)") != .glass(.regular))
    }

    test("material: the kind is case-insensitive") {
        try expectEqual(StackMaterial.parse("GLASS"), .glass(.regular))
        try expectEqual(StackMaterial.parse("Vibrancy.Sidebar"), .vibrancy(.sidebar))
    }

    test("material: missing, blank, none, unknown and malformed values → .none") {
        try expectEqual(StackMaterial.parse(nil), .none)
        for raw in ["", "   ", "none", "not-a-material", "vibrancy.notreal",
                    "glass.tinted(notahex)", "glass.tinted(#abc)"] {
            try expectEqual(StackMaterial.parse(raw), .none, "'\(raw)'")
        }
    }

    // MARK: StackCornerRadius

    test("cornerRadius: nil stays nil, non-negative passes through, negative clamps to 0") {
        try expect(StackCornerRadius.parse(nil) == nil)
        try expectEqual(StackCornerRadius.parse(12.0), 12.0)
        try expectEqual(StackCornerRadius.parse(0.0), 0.0)
        try expectEqual(StackCornerRadius.parse(-5.0), 0.0)
    }

    // MARK: StackShape
    //
    // Capsule shape ignores the manifest cornerRadius and uses min(w,h)/2 so
    // the window is a pill (horizontal or vertical) or circle. Rect uses the
    // manifest radius verbatim.

    test("shape: parse accepts capsule and the rect aliases, case-insensitive; anything else is rect") {
        try expectEqual(StackShape.parse("capsule"), .capsule)
        try expectEqual(StackShape.parse("CAPSULE"), .capsule)
        try expectEqual(StackShape.parse("Capsule"), .capsule)
        for raw in ["rect", "rectangle", "rounded", "", "blob"] {
            try expectEqual(StackShape.parse(raw), .rect, "'\(raw)'")
        }
        try expectEqual(StackShape.parse(nil), .rect)
    }

    test("shape.outerRadius: rect uses the manifest radius, clamped at 0") {
        let frame = CGSize(width: 200, height: 100)
        try expectEqual(StackShape.rect.outerRadius(frame: frame, manifestRadius: 24), 24)
        try expectEqual(StackShape.rect.outerRadius(frame: frame, manifestRadius: nil), 0)
        try expectEqual(StackShape.rect.outerRadius(frame: frame, manifestRadius: -5), 0)
    }

    test("shape.outerRadius: capsule is half the short side and ignores the manifest radius") {
        try expectEqual(StackShape.capsule.outerRadius(frame: CGSize(width: 200, height: 60),
                                                       manifestRadius: nil), 30, "horizontal pill")
        try expectEqual(StackShape.capsule.outerRadius(frame: CGSize(width: 80, height: 200),
                                                       manifestRadius: nil), 40, "vertical pill")
        try expectEqual(StackShape.capsule.outerRadius(frame: CGSize(width: 100, height: 100),
                                                       manifestRadius: nil), 50, "circle")
        try expectEqual(StackShape.capsule.outerRadius(frame: CGSize(width: 200, height: 60),
                                                       manifestRadius: 999), 30, "manifest radius ignored")
    }

    test("glassEdgeInset: tangent curvature gets the bleed inset, others zero") {
        // Circle: radius == min/2 → inset (the SDF bleed would clip flat at
        // all four cardinal edges otherwise).
        try expectEqual(
            StackShape.glassEdgeInset(outerRadius: 40, frame: CGSize(width: 80, height: 80)),
            StackShape.tangentBleedInset)
        // Capsule: radius == min(h)/2 on a wide pill → inset.
        try expectEqual(
            StackShape.glassEdgeInset(outerRadius: 24, frame: CGSize(width: 420, height: 48)),
            StackShape.tangentBleedInset)
        // Ordinary rounded rect: radius well under tangent → no inset.
        try expectEqual(
            StackShape.glassEdgeInset(outerRadius: 12, frame: CGSize(width: 420, height: 48)), 0)
        try expectEqual(
            StackShape.glassEdgeInset(outerRadius: 24, frame: CGSize(width: 800, height: 470)), 0)
        // No radius at all → no inset.
        try expectEqual(
            StackShape.glassEdgeInset(outerRadius: 0, frame: CGSize(width: 80, height: 80)), 0)
    }

    // MARK: StackPadding
    //
    // When a WebView is inset by P inside a material with outer cornerRadius
    // R, its inner cornerRadius is max(0, R - P) — parallel arcs sharing a
    // center. Mirrors SwiftUI's RoundedRectangularShapeCorners.concentric.

    test("padding: parse nil → 0, non-negative passes through, negative clamps to 0") {
        try expectEqual(StackPadding.parse(nil), 0)
        try expectEqual(StackPadding.parse(8), 8)
        try expectEqual(StackPadding.parse(0), 0)
        try expectEqual(StackPadding.parse(-3), 0)
    }

    // When the manifest omits `padding` on a glass material with
    // cornerRadius > 0, the daemon auto-defaults to cornerRadius/2. Explicit
    // manifest values (including 0) are respected. Non-glass materials
    // default to 0 (flush).

    test("effectivePadding: an explicit manifest value wins, clamped at 0") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: 6, material: .glass(.regular), cornerRadius: 24), 6)
        try expectEqual(
            StackPadding.effectivePadding(manifest: 0, material: .glass(.regular), cornerRadius: 24), 0,
            "explicit 0 opts out of the auto-default")
        try expectEqual(
            StackPadding.effectivePadding(manifest: -5, material: .glass(.regular), cornerRadius: 24), 0)
    }

    test("effectivePadding: every glass variant with a radius auto-defaults to cornerRadius/2") {
        let tint = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.regular), cornerRadius: 24), 12)
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.clear), cornerRadius: 16), 8)
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.tinted(tint)), cornerRadius: 30), 15)
    }

    test("effectivePadding: no auto-default without a radius or without glass") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.regular), cornerRadius: nil), 0)
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.regular), cornerRadius: 0), 0)
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .vibrancy(.hudWindow), cornerRadius: 24), 0)
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .none, cornerRadius: 24), 0)
    }

    test("concentric: inner radius is outer minus padding, collapsing to 0 at or past parity") {
        let cases: [(outer: Double, padding: Double, inner: Double)] = [
            (24, 8, 16), (24, 0, 24), (24, 24, 0), (24, 40, 0), (0, 0, 0),
        ]
        for c in cases {
            try expectEqual(StackPadding.concentricInnerRadius(outer: c.outer, padding: c.padding), c.inner,
                            "outer=\(c.outer) padding=\(c.padding)")
        }
    }

    // MARK: MaterialAttachment.mode
    //
    // Liquid Glass needs the WebView embedded INSIDE NSGlassEffectView's
    // `contentView` (sibling subviews are undefined per the SDK header).
    // Vibrancy and the pre-Tahoe glass fallback want the WebView as a sibling
    // above NSVisualEffectView so `blendingMode = .behindWindow` reads the
    // desktop. `.none` with no corner radius skips the container entirely.

    test("attachment: .none is direct content unless it has a corner radius to clip") {
        try expectEqual(MaterialAttachment.mode(material: .none, cornerRadius: nil, supportsGlass: true),
                        .directContent)
        try expectEqual(MaterialAttachment.mode(material: .none, cornerRadius: 0, supportsGlass: true),
                        .directContent)
        try expectEqual(MaterialAttachment.mode(material: .none, cornerRadius: 10, supportsGlass: true),
                        .siblingInContainer)
    }

    test("attachment: vibrancy is a sibling in a container on any macOS") {
        for glass in [true, false] {
            try expectEqual(
                MaterialAttachment.mode(material: .vibrancy(.hudWindow), cornerRadius: nil, supportsGlass: glass),
                .siblingInContainer)
        }
    }

    test("attachment: every glass variant embeds on Tahoe and falls back to a sibling before it") {
        let tint = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        for variant in [StackMaterial.GlassVariant.regular, .clear, .tinted(tint)] {
            try expectEqual(
                MaterialAttachment.mode(material: .glass(variant), cornerRadius: 12, supportsGlass: true),
                .embeddedInGlass, "\(variant) on Tahoe")
            try expectEqual(
                MaterialAttachment.mode(material: .glass(variant), cornerRadius: nil, supportsGlass: false),
                .siblingInContainer, "\(variant) pre-Tahoe")
        }
    }
}
