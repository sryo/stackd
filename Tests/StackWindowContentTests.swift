import AppKit

// The view hierarchy StackWindow builds for each MaterialAttachment mode:
// the webview as the content view, beside an effect view in a container,
// or embedded in a Liquid Glass view. Panels are built, never ordered in.

func registerStackWindowContentTests() {
    func window(_ material: StackMaterial, radius: Double? = nil, shape: StackShape = .rect,
                size: CGSize = CGSize(width: 40, height: 20)) -> StackWindow {
        StackWindow(frame: NSRect(origin: .zero, size: size), clickThrough: true,
                    schemeHandler: StackdSchemeHandler(runtimePath: "/nonexistent"),
                    material: material, cornerRadius: radius, shape: shape)
    }

    test("StackWindow content: no material and no radius puts the webview in directly") {
        let win = window(.none)
        try expect(win.contentView === win.webView, "the webview is the content view")
    }

    test("StackWindow content: no material with a radius clips the webview in a plain container") {
        let win = window(.none, radius: 8)
        let container = try unwrapView(win.contentView)
        try expect(container !== win.webView)
        try expectEqual(container.subviews.count, 1)
        try expect(container.subviews[0] === win.webView)
        try expectEqual(win.webView.layer?.cornerRadius, 8)
    }

    test("StackWindow content: vibrancy is an effect view behind the webview") {
        let win = window(.vibrancy(.sidebar), radius: 6)
        let container = try unwrapView(win.contentView)
        try expectEqual(container.subviews.count, 2)
        let effect = try unwrapView(container.subviews[0] as? NSVisualEffectView)
        try expectEqual(effect.material, .sidebar)
        try expectEqual(effect.blendingMode, .behindWindow)
        try expectEqual(effect.state, .active)
        try expectEqual(effect.layer?.cornerRadius, 6)
        try expect(container.subviews[1] === win.webView, "the webview sits above the effect view")
        try expectEqual(win.webView.layer?.cornerRadius, 6)
    }

    test("StackWindow content: glass embeds the webview in a glass view, or falls back to HUD vibrancy") {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let win = window(.glass(.tinted(red)), radius: 6)
        if #available(macOS 26.0, *) {
            let glass = try unwrapView(win.contentView as? NSGlassEffectView)
            try expectEqual(glass.style, .regular)
            try expectEqual(glass.tintColor, red)
            try expectEqual(glass.cornerRadius, 6)
            try expect(glass.contentView === win.webView, "the webview is the glass view's content")
        } else {
            let container = try unwrapView(win.contentView)
            let effect = try unwrapView(container.subviews.first as? NSVisualEffectView)
            try expectEqual(effect.material, .hudWindow)
            try expect(container.subviews.last === win.webView)
        }
    }

    test("StackWindow content: a capsule glass view is inset inside a full-size container") {
        let win = window(.glass(.clear), shape: .capsule)
        if #available(macOS 26.0, *) {
            let container = try unwrapView(win.contentView)
            try expect(!(container is NSGlassEffectView), "the inset glass view needs a container")
            let glass = try unwrapView(container.subviews.first as? NSGlassEffectView)
            let inset = CGFloat(StackShape.tangentBleedInset)
            try expectEqual(glass.frame, NSRect(x: inset, y: inset, width: 40 - 2 * inset, height: 20 - 2 * inset))
            try expectEqual(glass.style, .clear)
            try expectEqual(glass.cornerRadius, 10 - inset)
            try expect(glass.contentView === win.webView)
            try expectEqual(win.webView.layer?.cornerRadius, 10 - inset)
        }
    }
}

private func unwrapView<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    try expect(value != nil, "expected a view", file: file, line: line)
    return value!
}
