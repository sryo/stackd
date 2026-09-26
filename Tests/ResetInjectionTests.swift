import Foundation

/// Tests for the CSS reset that Bridge injects into every stack by default.
/// The injection itself happens through a WKUserScript (no WKWebView harness
/// here), so we pin the reset's cascade contract plus the manifest opt-out
/// field that StackHost reads as `manifest.reset ?? true`.
func registerResetInjectionTests() {
    test("reset style: zero-specificity :where(html,body) wrapper so stack CSS wins") {
        // Dropping :where() would let the reset override stack rules that
        // share the same selector.
        try expect(Bridge.resetStyle.hasPrefix(":where(html,body)"),
                   "reset must be scoped by :where(html,body), got \(Bridge.resetStyle)")
    }

    test("reset style: zeroes margin / padding, clears background, disables selection") {
        let s = Bridge.resetStyle
        for decl in ["margin:0", "padding:0", "background:transparent",
                     "user-select:none", "-webkit-user-select:none"] {
            try expect(s.contains(decl), "reset missing '\(decl)': \(s)")
        }
    }

    test("manifest: reset decodes nil when missing, and explicit true / false") {
        func decode(_ extra: String) throws -> StackManifest {
            let json = #"{"id":"x","name":"X","size":{"w":1,"h":1},"permissions":[]"# + extra + "}"
            return try JSONDecoder().decode(StackManifest.self, from: Data(json.utf8))
        }
        try expectEqual(try decode("").reset, nil)
        try expectEqual(try decode(#","reset":false"#).reset, false)
        try expectEqual(try decode(#","reset":true"#).reset, true)
    }
}
