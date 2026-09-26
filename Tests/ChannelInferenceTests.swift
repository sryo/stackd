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

    test("multiple references in one source accumulate") {
        let src = """
        sd.fs.read('~/x'); sd.windows.focused.subscribe(w => sd.notify.show({title: w.title}));
        sd.proc.exec('/bin/echo', ['hi']);
        """
        try expectEqual(ChannelInference.infer(from: src), ["fs", "windows", "notify", "proc"])
    }
}
