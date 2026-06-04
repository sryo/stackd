import Foundation

func registerChannelInferenceTests() {
    test("infer 'battery' from sd.battery.percent reference") {
        let html = """
        <script>
          import { sd } from "sd://runtime/api.js";
          sd.bind(el, sd.battery, b => b.percent + "%");
        </script>
        """
        let perms = ChannelInference.infer(from: html)
        try expect(perms.contains("battery"), "expected 'battery' in \(perms.sorted())")
    }

    test("infer top-level channel 'mouse' from sd.mouse usage") {
        let perms = ChannelInference.infer(from: "sd.bind(x, sd.mouse, m => m.x)")
        try expect(perms.contains("mouse"))
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

    test("left boundary: xsd.battery does not infer 'battery'") {
        let perms = ChannelInference.infer(from: "const xsd = {}; xsd.battery;")
        try expect(!perms.contains("battery"))
    }

    test("no sd.* references returns empty set") {
        let perms = ChannelInference.infer(from: "const x = 1; console.log('hello');")
        try expectEqual(perms, [])
    }

    test("multiple references accumulate") {
        let src = "sd.bind(el, sd.battery, …); sd.bind(el, sd.mouse, …);"
        let perms = ChannelInference.infer(from: src)
        try expect(perms.contains("battery"))
        try expect(perms.contains("mouse"))
    }

    // ----- expanded inference (R4.1) ----------------------------------------
    // Identity inference for RPC namespaces: sd.fs.read / sd.proc.exec / etc.
    // imply their respective permissions without an explicit manifest entry.

    test("infer 'fs' from sd.fs.read call") {
        let perms = ChannelInference.infer(from: "await sd.fs.read('~/notes.txt');")
        try expect(perms.contains("fs"), "expected 'fs' in \(perms.sorted())")
    }

    test("infer 'proc' from sd.proc.exec call") {
        let perms = ChannelInference.infer(from: "sd.proc.exec('/bin/ls', []);")
        try expect(perms.contains("proc"))
    }

    test("infer 'applescript' from sd.applescript.run does NOT also imply 'app'") {
        // Boundary regression guard — the previous-char check must reject
        // `sd.app.` matching inside `sd.applescript`. If this fails, every
        // stack that uses AppleScript silently gets a stray 'app' permission.
        let perms = ChannelInference.infer(from: "await sd.applescript.run(['tell …']);")
        try expect(perms.contains("applescript"))
        try expect(!perms.contains("app"), "boundary leaked: 'app' inferred from sd.applescript")
    }

    test("infer 'apps' from sd.apps.running does NOT also imply 'app'") {
        let perms = ChannelInference.infer(from: "sd.apps.running.subscribe(list => render(list));")
        try expect(perms.contains("apps"))
        try expect(!perms.contains("app"), "boundary leaked: 'app' inferred from sd.apps")
    }

    test("infer 'pasteboard' from sd.pasteboard.set") {
        let perms = ChannelInference.infer(from: "await sd.pasteboard.set('hello');")
        try expect(perms.contains("pasteboard"))
    }

    test("infer 'httpserver' from sd.httpserver.serve") {
        let perms = ChannelInference.infer(from: "const srv = await sd.httpserver.serve({port: 8080}, cb);")
        try expect(perms.contains("httpserver"))
    }

    test("composite permission 'menubar.item' is NOT auto-inferred (requires explicit opt-in)") {
        // Composites carry stricter side-effects than their base namespace
        // (menubar.observe is read-only; menubar.item mutates the system bar).
        // Authors must opt in explicitly so the surface stays visible at review.
        let perms = ChannelInference.infer(from: "sd.menubar.addItem({title:'x'});")
        try expect(perms.contains("menubar"))
        try expect(!perms.contains("menubar.item"), "composite should require explicit declaration")
    }

    test("inference covers a realistic multi-permission stack source") {
        let src = """
        sd.fs.read('~/x'); sd.windows.focused.subscribe(w => sd.notify.show({title: w.title}));
        sd.proc.exec('/bin/echo', ['hi']);
        """
        let perms = ChannelInference.infer(from: src)
        try expect(perms.contains("fs"))
        try expect(perms.contains("windows"))
        try expect(perms.contains("notify"))
        try expect(perms.contains("proc"))
    }
}
