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
}
