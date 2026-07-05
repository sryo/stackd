import Foundation

// Tests for Symbols.swift — SF Symbol → template PNG data-URL. Rendering
// runs through AppKit on a live macOS host (the test process can lockFocus /
// draw), so we exercise the real path: a known-good system symbol must
// produce a PNG data-URL with positive natural dimensions, and an unknown
// symbol name must fail cleanly (nil, not a crash or an empty image).
// The permission ("symbol" in Permissions.all) is cross-validated separately
// by PermissionsRegistryTests.

func registerSymbolsTests() {
    test("render returns a png data-URL with positive dimensions for a real symbol") {
        guard let out = Symbols.render(name: "bolt.fill", pointSize: 15, weight: "regular", scale: "medium") else {
            throw Expectation(message: "expected a render for bolt.fill, got nil")
        }
        let url = out["dataURL"] as? String ?? ""
        try expect(url.hasPrefix("data:image/png;base64,"), "dataURL should be a base64 png, got: \(url.prefix(32))")
        try expect((url.count) > "data:image/png;base64,".count, "dataURL should carry payload bytes")
        try expect((out["width"] as? Int ?? 0) > 0, "width should be positive")
        try expect((out["height"] as? Int ?? 0) > 0, "height should be positive")
    }

    test("render returns nil for an unknown symbol name") {
        try expect(Symbols.render(name: "definitely.not.a.real.symbol.zzz", pointSize: 15, weight: "regular", scale: "medium") == nil,
                   "unknown symbol name should render nil")
    }

    test("render returns nil for an empty name") {
        try expect(Symbols.render(name: "", pointSize: 15, weight: "regular", scale: "medium") == nil,
                   "empty name should render nil")
    }

    test("unknown weight / scale fall back instead of failing") {
        // A real symbol with bogus weight/scale strings must still render —
        // the maps default to .regular / .medium rather than dropping the glyph.
        try expect(Symbols.render(name: "circle", pointSize: 13, weight: "nonsense", scale: "nonsense") != nil,
                   "bogus weight/scale should fall back, not nil out a valid symbol")
    }
}
