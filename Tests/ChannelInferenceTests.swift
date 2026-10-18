import Foundation

// Per-namespace identity inference (sd.fs → "fs", sd.proc → "proc", …) is
// covered exhaustively by PermissionsRegistryTests, which walks every entry
// in Permissions.inferable. This file covers the scanner's boundary rules,
// sub-path mappings, and composite exclusion.
func registerChannelInferenceTests() {
    test("infer 'battery' from sd.bind(el, sd.battery, …) inside a <script> block") {
        let html = """
        <script>
          import { sd } from "sd://runtime/api.js";
          sd.bind(el, sd.battery, b => b.percent + "%");
        </script>
        """
        let perms = ChannelInference.infer(from: html)
        try expect(perms.contains("battery"), "expected 'battery' in \(perms.sorted())")
    }

    test("infer sub-path 'app' from sd.app.frontmost (NOT 'app.frontmost')") {
        let perms = ChannelInference.infer(from: "sd.app.frontmost.subscribe(a => …)")
        try expect(perms.contains("app"), "expected 'app' in \(perms.sorted())")
        try expect(!perms.contains("app.frontmost"), "should not expose raw sub-path")
    }

    test("right boundary: sd.batteryFoo does not infer 'battery'") {
        let perms = ChannelInference.infer(from: "let batteryFoo = sd.batteryFoo;")
        try expect(!perms.contains("battery"), "boundary leaked: \(perms.sorted())")
    }

    test("left boundary: xsd.battery / foo.sd.battery do not infer 'battery'") {
        try expect(!ChannelInference.infer(from: "const xsd = {}; xsd.battery;").contains("battery"))
        try expect(!ChannelInference.infer(from: "foo.sd.battery").contains("battery"))
    }

    test("no sd.* references returns empty set") {
        let perms = ChannelInference.infer(from: "const x = 1; console.log('hello');")
        try expectEqual(perms, [])
    }

    test("sd.applescript.run infers 'applescript' but NOT 'app'") {
        let perms = ChannelInference.infer(from: "await sd.applescript.run(['tell …']);")
        try expect(perms.contains("applescript"))
        try expect(!perms.contains("app"), "boundary leaked: 'app' inferred from sd.applescript")
    }

    test("sd.apps.running infers 'apps' but NOT 'app'") {
        let perms = ChannelInference.infer(from: "sd.apps.running.subscribe(list => render(list));")
        try expect(perms.contains("apps"))
        try expect(!perms.contains("app"), "boundary leaked: 'app' inferred from sd.apps")
    }

    test("sub-path helper sd.gesture.spring infers 'displayLink'") {
        // The spring helper ticks on sd.displayLink without naming it.
        let perms = ChannelInference.infer(from: "const s = sd.gesture.spring({stiffness: 200});")
        try expect(perms.contains("displayLink"), "expected 'displayLink' in \(perms.sorted())")
    }

    test("composite permission 'menubar.item' is NOT auto-inferred (requires explicit opt-in)") {
        // Composites carry stricter side-effects than their base namespace
        // (menubar.observe is read-only; menubar.item mutates the system bar).
        let perms = ChannelInference.infer(from: "sd.menubar.addItem({title:'x'}); sd.menubar.item;")
        try expect(perms.contains("menubar"))
        try expect(!perms.contains("menubar.item"), "composite should require explicit declaration")
    }

    test("overlapping names infer only the one each reference spells") {
        try expectEqual(ChannelInference.infer(from: "sd.displayLink.subscribe(f)"), ["displayLink"])
        try expectEqual(ChannelInference.infer(from: "sd.display.all"), ["display"])
        try expectEqual(ChannelInference.infer(from: "sd.app,sd.apps;sd.applescript"), ["app", "apps", "applescript"])
        try expectEqual(ChannelInference.infer(from: "sd.windows.focused"), ["windows"])
    }

    test("a reference at the very end or start of the text still counts") {
        try expectEqual(ChannelInference.infer(from: "sd.battery"), ["battery"])
        try expectEqual(ChannelInference.infer(from: "x = sd.usb"), ["usb"])
        try expectEqual(ChannelInference.infer(from: "sd."), [])
        try expectEqual(ChannelInference.infer(from: "sd"), [])
        try expectEqual(ChannelInference.infer(from: ""), [])
    }

    test("a rejected occurrence doesn't hide a later valid one") {
        try expectEqual(ChannelInference.infer(from: "xsd.battery; sd.batteryX; sd.battery.percent"), ["battery"])
        try expectEqual(ChannelInference.infer(from: "sd.sd.battery"), [])
        try expectEqual(ChannelInference.infer(from: "$sd.usb _sd.usb 1sd.usb"), [])
        try expectEqual(ChannelInference.infer(from: "(sd.usb)[sd.camera]{sd.mouse}"), ["usb", "camera", "mouse"])
    }

    test("boundaries are judged on whole characters, unicode included") {
        // Non-ASCII punctuation and symbols are boundaries; letters are not.
        try expectEqual(ChannelInference.infer(from: "→sd.battery✓"), ["battery"])
        try expectEqual(ChannelInference.infer(from: "🔋sd.battery🔋"), ["battery"])
        try expectEqual(ChannelInference.infer(from: "«sd.usb»"), ["usb"])
        try expectEqual(ChannelInference.infer(from: "ésd.battery"), [])
        try expectEqual(ChannelInference.infer(from: "sd.batteryé"), [])
        try expectEqual(ChannelInference.infer(from: "sd.battery日本"), [])
        try expectEqual(ChannelInference.infer(from: "日本sd.battery"), [])
        try expectEqual(ChannelInference.infer(from: "sd.battery٣"), [])
        // A combining mark joins the character before it, so `y` + U+0301
        // is not the `y` that ends "battery".
        try expectEqual(ChannelInference.infer(from: "sd.battery\u{301}.percent"), [])
        // ...and an accented letter before `sd` is still a letter.
        try expectEqual(ChannelInference.infer(from: "e\u{301}sd.battery"), [])
        // CRLF is one character and a boundary.
        try expectEqual(ChannelInference.infer(from: "\r\nsd.usb\r\n"), ["usb"])
    }

    test("multiple references in one source accumulate") {
        let src = """
        sd.fs.read('~/x'); sd.windows.focused.subscribe(w => sd.notify.show({title: w.title}));
        sd.proc.exec('/bin/echo', ['hi']);
        """
        try expectEqual(ChannelInference.infer(from: src), ["fs", "windows", "notify", "proc"])
    }
}
