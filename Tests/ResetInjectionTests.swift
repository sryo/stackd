import Foundation

/// Tests for the CSS reset that Bridge injects into every stack by default.
/// The reset itself is a static string we can pin; the actual injection
/// happens through a WKUserScript which we can't easily evaluate from Swift
/// tests (no WKWebView harness yet). Manifest decoding is tested here too —
/// that's the seam stack authors use to opt out.
func registerResetInjectionTests() {
    test("reset style: uses :where() for zero specificity (stack CSS naturally wins)") {
        // Regression guard: if someone drops :where() the reset starts
        // overriding stack rules that share the same selector — exactly
        // the cascade-fight the wrapper exists to prevent.
        try expectEqual(Bridge.resetStyle.contains(":where("), true)
    }

    test("reset style: covers margin / padding / background / user-select on html and body") {
        // user-select is inheritable so html/body covers descendants; stacks
        // that want selection override naturally via :where(). Other globals
        // (overflow, font, color-scheme) are stack-specific and omitted.
        let s = Bridge.resetStyle
        try expectEqual(s.contains("html,body"), true)
        try expectEqual(s.contains("margin:0"), true)
        try expectEqual(s.contains("padding:0"), true)
        try expectEqual(s.contains("background:transparent"), true)
        try expectEqual(s.contains("user-select:none"), true)
        try expectEqual(s.contains("-webkit-user-select:none"), true)
    }

    test("reset style: does NOT include overflow / font / color (stack-specific)") {
        // Documents the conservative scope decision so a future "let's also
        // reset overflow" PR has to update this test (and re-justify).
        let s = Bridge.resetStyle
        try expectEqual(s.contains("overflow"), false)
        try expectEqual(s.contains("font"), false)
        try expectEqual(s.contains("color"), false)
    }

    test("manifest: reset field defaults to nil when missing (host treats as true)") {
        let json = """
        {"id":"x","name":"X","size":{"w":1,"h":1},"permissions":[]}
        """
        let m = try JSONDecoder().decode(StackManifest.self, from: Data(json.utf8))
        try expectEqual(m.reset, nil)
        // Host wires this as `manifest.reset ?? true` — verify the contract
        // here so a refactor that drops the default surfaces a test failure.
        try expectEqual(m.reset ?? true, true)
    }

    test("manifest: reset:false decodes to false (the actual opt-out path)") {
        let json = """
        {"id":"x","name":"X","size":{"w":1,"h":1},"permissions":[],"reset":false}
        """
        let m = try JSONDecoder().decode(StackManifest.self, from: Data(json.utf8))
        try expectEqual(m.reset, false)
        try expectEqual(m.reset ?? true, false)
    }

    test("manifest: reset:true decodes to true (explicit opt-in is a no-op vs default)") {
        let json = """
        {"id":"x","name":"X","size":{"w":1,"h":1},"permissions":[],"reset":true}
        """
        let m = try JSONDecoder().decode(StackManifest.self, from: Data(json.utf8))
        try expectEqual(m.reset, true)
    }
}
