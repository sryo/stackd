import AppKit
import Foundation

/// Tests for the unified material model (`StackMaterial.parse` +
/// `StackCornerRadius.parse`). The decoder is pure — no AppKit state touched
/// beyond constructing `NSVisualEffectView.Material` / `NSColor` values — so
/// we cover it end-to-end here. The installation side (NSGlassEffectView
/// vs NSVisualEffectView) is impure (macOS state) and stays untested per
/// project rule: test through public interfaces, not private installation.
func registerMaterialTests() {

    // MARK: legacy bare aliases (backwards compat — currently shipping stacks)

    test("material: legacy 'sidebar' → vibrancy.sidebar") {
        try expectEqual(StackMaterial.parse("sidebar"), .vibrancy(.sidebar))
    }
    test("material: legacy 'hud' → vibrancy.hudWindow") {
        try expectEqual(StackMaterial.parse("hud"), .vibrancy(.hudWindow))
    }
    test("material: legacy 'popover' → vibrancy.popover") {
        try expectEqual(StackMaterial.parse("popover"), .vibrancy(.popover))
    }
    test("material: legacy 'menu' → vibrancy.menu") {
        try expectEqual(StackMaterial.parse("menu"), .vibrancy(.menu))
    }
    test("material: legacy 'titlebar' → vibrancy.titlebar") {
        try expectEqual(StackMaterial.parse("titlebar"), .vibrancy(.titlebar))
    }
    test("material: legacy 'sheet' → vibrancy.sheet") {
        try expectEqual(StackMaterial.parse("sheet"), .vibrancy(.sheet))
    }
    test("material: legacy 'window' → vibrancy.windowBackground") {
        try expectEqual(StackMaterial.parse("window"), .vibrancy(.windowBackground))
    }
    test("material: legacy 'header' → vibrancy.headerView") {
        try expectEqual(StackMaterial.parse("header"), .vibrancy(.headerView))
    }
    test("material: legacy 'selection' → vibrancy.selection") {
        try expectEqual(StackMaterial.parse("selection"), .vibrancy(.selection))
    }
    test("material: legacy 'glass' → glass(.regular)") {
        try expectEqual(StackMaterial.parse("glass"), .glass(.regular))
    }

    // MARK: explicit vibrancy.* forms

    test("material: explicit 'vibrancy.sidebar' decodes") {
        try expectEqual(StackMaterial.parse("vibrancy.sidebar"), .vibrancy(.sidebar))
    }
    test("material: explicit 'vibrancy.hud' decodes") {
        try expectEqual(StackMaterial.parse("vibrancy.hud"), .vibrancy(.hudWindow))
    }
    test("material: explicit 'vibrancy.popover' decodes") {
        try expectEqual(StackMaterial.parse("vibrancy.popover"), .vibrancy(.popover))
    }
    test("material: explicit 'vibrancy.menu' decodes") {
        try expectEqual(StackMaterial.parse("vibrancy.menu"), .vibrancy(.menu))
    }
    test("material: explicit 'vibrancy.titlebar' decodes") {
        try expectEqual(StackMaterial.parse("vibrancy.titlebar"), .vibrancy(.titlebar))
    }
    test("material: explicit 'vibrancy.sheet' decodes") {
        try expectEqual(StackMaterial.parse("vibrancy.sheet"), .vibrancy(.sheet))
    }
    test("material: explicit 'vibrancy.window' decodes") {
        try expectEqual(StackMaterial.parse("vibrancy.window"), .vibrancy(.windowBackground))
    }
    test("material: explicit 'vibrancy.header' decodes") {
        try expectEqual(StackMaterial.parse("vibrancy.header"), .vibrancy(.headerView))
    }
    test("material: explicit 'vibrancy.selection' decodes") {
        try expectEqual(StackMaterial.parse("vibrancy.selection"), .vibrancy(.selection))
    }

    // MARK: glass family

    test("material: 'glass.clear' decodes") {
        try expectEqual(StackMaterial.parse("glass.clear"), .glass(.clear))
    }
    test("material: 'glass.tinted(#RRGGBB)' decodes with correct color") {
        let result = StackMaterial.parse("glass.tinted(#ff8800)")
        let expected = NSColor(srgbRed: 1.0, green: 136/255.0, blue: 0.0, alpha: 1.0)
        try expectEqual(result, .glass(.tinted(expected)))
    }
    test("material: 'glass.tinted(#RRGGBBAA)' decodes alpha channel") {
        let result = StackMaterial.parse("glass.tinted(#00ff0080)")
        let expected = NSColor(srgbRed: 0.0, green: 1.0, blue: 0.0, alpha: 128/255.0)
        try expectEqual(result, .glass(.tinted(expected)))
    }
    test("material: 'glass.tinted' tolerates case in hex") {
        let result = StackMaterial.parse("glass.tinted(#FF8800)")
        let expected = NSColor(srgbRed: 1.0, green: 136/255.0, blue: 0.0, alpha: 1.0)
        try expectEqual(result, .glass(.tinted(expected)))
    }

    // MARK: case-insensitive kind

    test("material: kind is case-insensitive ('GLASS' → glass.regular)") {
        try expectEqual(StackMaterial.parse("GLASS"), .glass(.regular))
    }
    test("material: kind is case-insensitive ('Vibrancy.Sidebar' → vibrancy.sidebar)") {
        try expectEqual(StackMaterial.parse("Vibrancy.Sidebar"), .vibrancy(.sidebar))
    }

    // MARK: empty / none / unknown

    test("material: nil manifest → .none") {
        try expectEqual(StackMaterial.parse(nil), .none)
    }
    test("material: empty string → .none") {
        try expectEqual(StackMaterial.parse(""), .none)
    }
    test("material: whitespace string → .none") {
        try expectEqual(StackMaterial.parse("   "), .none)
    }
    test("material: literal 'none' → .none") {
        try expectEqual(StackMaterial.parse("none"), .none)
    }
    test("material: unknown string → .none (no crash)") {
        try expectEqual(StackMaterial.parse("not-a-material"), .none)
    }
    test("material: unknown vibrancy key → .none") {
        try expectEqual(StackMaterial.parse("vibrancy.notreal"), .none)
    }
    test("material: bad hex in glass.tinted → .none") {
        try expectEqual(StackMaterial.parse("glass.tinted(notahex)"), .none)
    }
    test("material: too-short hex in glass.tinted → .none") {
        try expectEqual(StackMaterial.parse("glass.tinted(#abc)"), .none)
    }
    test("material: missing # in glass.tinted still parses (lenient)") {
        // We don't require the leading '#' — both forms accepted.
        let result = StackMaterial.parse("glass.tinted(ff8800)")
        let expected = NSColor(srgbRed: 1.0, green: 136/255.0, blue: 0.0, alpha: 1.0)
        try expectEqual(result, .glass(.tinted(expected)))
    }

    // MARK: cornerRadius

    test("cornerRadius: nil → nil") {
        try expect(StackCornerRadius.parse(nil) == nil)
    }
    test("cornerRadius: positive Double passes through") {
        try expectEqual(StackCornerRadius.parse(12.0), 12.0)
    }
    test("cornerRadius: zero passes through") {
        try expectEqual(StackCornerRadius.parse(0.0), 0.0)
    }
    test("cornerRadius: negative clamps to 0") {
        try expectEqual(StackCornerRadius.parse(-5.0), 0.0)
    }

    // MARK: StackShape — capsule vs rect outer-radius decision
    //
    // Capsule shape ignores the manifest cornerRadius and uses min(w,h)/2 so
    // the window is a pill (horizontal or vertical) or circle. Rect uses the
    // manifest radius verbatim.

    test("shape: parse 'capsule' → .capsule") {
        try expectEqual(StackShape.parse("capsule"), .capsule)
    }
    test("shape: parse 'rect' → .rect") {
        try expectEqual(StackShape.parse("rect"), .rect)
    }
    test("shape: parse 'rectangle' (alias) → .rect") {
        try expectEqual(StackShape.parse("rectangle"), .rect)
    }
    test("shape: parse nil → .rect (default)") {
        try expectEqual(StackShape.parse(nil), .rect)
    }
    test("shape: parse empty → .rect (default)") {
        try expectEqual(StackShape.parse(""), .rect)
    }
    test("shape: parse unknown → .rect (fallback, no crash)") {
        try expectEqual(StackShape.parse("blob"), .rect)
    }
    test("shape: parse is case-insensitive") {
        try expectEqual(StackShape.parse("CAPSULE"), .capsule)
        try expectEqual(StackShape.parse("Capsule"), .capsule)
    }

    test("shape.outerRadius: rect honors manifest radius") {
        try expectEqual(
            StackShape.rect.outerRadius(frame: CGSize(width: 200, height: 100), manifestRadius: 24),
            24)
    }
    test("shape.outerRadius: rect with nil manifest radius → 0") {
        try expectEqual(
            StackShape.rect.outerRadius(frame: CGSize(width: 200, height: 100), manifestRadius: nil),
            0)
    }
    test("shape.outerRadius: rect with negative manifest radius → 0") {
        try expectEqual(
            StackShape.rect.outerRadius(frame: CGSize(width: 200, height: 100), manifestRadius: -5),
            0)
    }
    test("shape.outerRadius: capsule on wide frame → height/2 (horizontal pill)") {
        try expectEqual(
            StackShape.capsule.outerRadius(frame: CGSize(width: 200, height: 60), manifestRadius: nil),
            30)
    }
    test("shape.outerRadius: capsule on tall frame → width/2 (vertical pill)") {
        try expectEqual(
            StackShape.capsule.outerRadius(frame: CGSize(width: 80, height: 200), manifestRadius: nil),
            40)
    }
    test("shape.outerRadius: capsule on square frame → side/2 (circle)") {
        try expectEqual(
            StackShape.capsule.outerRadius(frame: CGSize(width: 100, height: 100), manifestRadius: nil),
            50)
    }
    test("shape.outerRadius: capsule ignores manifest radius") {
        try expectEqual(
            StackShape.capsule.outerRadius(frame: CGSize(width: 200, height: 60), manifestRadius: 999),
            30)
    }

    // MARK: StackPadding — concentric inner-corner formula
    //
    // When a WebView is inset by P inside a material with outer cornerRadius
    // R, its inner cornerRadius is max(0, R - P) — parallel arcs sharing a
    // center. Mirrors SwiftUI's RoundedRectangularShapeCorners.concentric.

    test("padding: parse nil → 0") {
        try expectEqual(StackPadding.parse(nil), 0)
    }
    test("padding: parse positive passes through") {
        try expectEqual(StackPadding.parse(8), 8)
    }
    test("padding: parse zero passes through") {
        try expectEqual(StackPadding.parse(0), 0)
    }
    test("padding: parse negative clamps to 0") {
        try expectEqual(StackPadding.parse(-3), 0)
    }

    // MARK: StackPadding.effectivePadding — daemon-side auto-default
    //
    // Stacks don't have to hand-tune padding to get a visible glass rim. When
    // the manifest omits `padding` on a glass material with cornerRadius > 0,
    // the daemon auto-defaults to cornerRadius/2 — padding == innerRadius for
    // pleasing symmetry. Explicit manifest values (including 0) are
    // respected verbatim. Non-glass materials default to 0 (flush).

    test("effectivePadding: explicit value wins over auto-default") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: 6, material: .glass(.regular), cornerRadius: 24),
            6)
    }
    test("effectivePadding: explicit 0 wins (opt out of auto-default)") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: 0, material: .glass(.regular), cornerRadius: 24),
            0)
    }
    test("effectivePadding: explicit negative clamps to 0") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: -5, material: .glass(.regular), cornerRadius: 24),
            0)
    }
    test("effectivePadding: glass + cornerRadius → cornerRadius/2 (auto)") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.regular), cornerRadius: 24),
            12)
    }
    test("effectivePadding: glass.clear + cornerRadius → cornerRadius/2 (auto)") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.clear), cornerRadius: 16),
            8)
    }
    test("effectivePadding: glass.tinted + cornerRadius → cornerRadius/2 (auto)") {
        let c = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.tinted(c)), cornerRadius: 30),
            15)
    }
    test("effectivePadding: glass with no cornerRadius → 0 (nothing to inset from)") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.regular), cornerRadius: nil),
            0)
    }
    test("effectivePadding: glass with cornerRadius=0 → 0") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .glass(.regular), cornerRadius: 0),
            0)
    }
    test("effectivePadding: vibrancy → 0 (no auto-default for vibrancy)") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .vibrancy(.hudWindow), cornerRadius: 24),
            0)
    }
    test("effectivePadding: .none → 0 (no material, no rim)") {
        try expectEqual(
            StackPadding.effectivePadding(manifest: nil, material: .none, cornerRadius: 24),
            0)
    }

    test("concentric: outer=24 padding=8 → inner=16") {
        try expectEqual(StackPadding.concentricInnerRadius(outer: 24, padding: 8), 16)
    }
    test("concentric: outer=24 padding=0 → inner=24") {
        try expectEqual(StackPadding.concentricInnerRadius(outer: 24, padding: 0), 24)
    }
    test("concentric: outer=24 padding=24 → inner=0 (collapse at parity)") {
        try expectEqual(StackPadding.concentricInnerRadius(outer: 24, padding: 24), 0)
    }
    test("concentric: outer=24 padding=40 → inner=0 (padding exceeds outer)") {
        try expectEqual(StackPadding.concentricInnerRadius(outer: 24, padding: 40), 0)
    }
    test("concentric: outer=0 padding=0 → inner=0 (sharp content in sharp container)") {
        try expectEqual(StackPadding.concentricInnerRadius(outer: 0, padding: 0), 0)
    }

    // MARK: MaterialAttachment.mode — view-hierarchy decision
    //
    // Liquid Glass needs the WebView embedded INSIDE NSGlassEffectView's
    // `contentView` (sibling subviews are undefined per the SDK header).
    // Vibrancy and the pre-Tahoe glass fallback want the WebView as a sibling
    // above NSVisualEffectView so `blendingMode = .behindWindow` reads the
    // desktop. `.none` with no corner radius skips the container entirely.

    test("attachment: .none + no radius → directContent") {
        try expectEqual(
            MaterialAttachment.mode(material: .none, cornerRadius: nil, supportsGlass: true),
            .directContent)
    }
    test("attachment: .none + zero radius → directContent (clamped)") {
        try expectEqual(
            MaterialAttachment.mode(material: .none, cornerRadius: 0, supportsGlass: true),
            .directContent)
    }
    test("attachment: .none + positive radius → siblingInContainer (rounded transparent)") {
        try expectEqual(
            MaterialAttachment.mode(material: .none, cornerRadius: 10, supportsGlass: true),
            .siblingInContainer)
    }
    test("attachment: .vibrancy(.hudWindow) → siblingInContainer (any macOS)") {
        try expectEqual(
            MaterialAttachment.mode(material: .vibrancy(.hudWindow), cornerRadius: nil, supportsGlass: true),
            .siblingInContainer)
        try expectEqual(
            MaterialAttachment.mode(material: .vibrancy(.hudWindow), cornerRadius: nil, supportsGlass: false),
            .siblingInContainer)
    }
    test("attachment: .glass(.regular) on Tahoe → embeddedInGlass") {
        try expectEqual(
            MaterialAttachment.mode(material: .glass(.regular), cornerRadius: nil, supportsGlass: true),
            .embeddedInGlass)
    }
    test("attachment: .glass(.regular) pre-Tahoe → siblingInContainer (fallback)") {
        try expectEqual(
            MaterialAttachment.mode(material: .glass(.regular), cornerRadius: nil, supportsGlass: false),
            .siblingInContainer)
    }
    test("attachment: .glass(.clear) on Tahoe → embeddedInGlass") {
        try expectEqual(
            MaterialAttachment.mode(material: .glass(.clear), cornerRadius: 12, supportsGlass: true),
            .embeddedInGlass)
    }
    test("attachment: .glass(.tinted) on Tahoe → embeddedInGlass") {
        let color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        try expectEqual(
            MaterialAttachment.mode(material: .glass(.tinted(color)), cornerRadius: nil, supportsGlass: true),
            .embeddedInGlass)
    }
    test("attachment: .glass(.tinted) pre-Tahoe → siblingInContainer (fallback)") {
        let color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        try expectEqual(
            MaterialAttachment.mode(material: .glass(.tinted(color)), cornerRadius: nil, supportsGlass: false),
            .siblingInContainer)
    }
}
