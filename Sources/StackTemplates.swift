import Foundation

/// Templates baked into the `stackd new` scaffolder. Each template is a
/// dictionary of relative-path → file-contents. The `{{name}}` token in
/// any value is replaced with the stack id at scaffold time.
///
/// Templates are intentionally small. Anything more elaborate belongs in
/// the `examples/` directory at the repo root — users copy those in
/// manually when they want a real reference.
enum StackTemplates {
    static let all: [String: [String: String]] = [
        "hello":   helloTemplate,
        "glass":   glassTemplate,
        "menubar": menubarTemplate,
        "hud":     hudTemplate
    ]

    // MARK: - hello

    /// Minimal panel that shows battery + theme — exercises sd.bind on three
    /// targets (textContent, dataset, CSS variable). Good first stack.
    private static let helloTemplate: [String: String] = [
        "stack.json": """
        {
          "id": "{{name}}",
          "name": "{{name}}",
          "anchor": { "edge": "top-right", "inset": [16, 16] },
          "size":   { "w": 200, "h": 64 },
          "permissions": ["battery", "appearance"]
        }

        """,
        "index.html": """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><link rel="stylesheet" href="index.css"></head>
        <body>
          <div class="card">
            <div class="title">{{name}}</div>
            <div class="value" id="value">…</div>
          </div>
          <script type="module">
            import { sd } from "sd://runtime/api.js";
            sd.bind(value,                            sd.battery,    b => b ? `${b.percent}% ${b.charging ? "⚡" : ""}` : "…");
            sd.bind([document.body, "data-theme"],    sd.appearance, a => a?.dark ? "dark" : "light");
            sd.bind([document.documentElement, "style.--sd-accent"], sd.appearance, a => a?.accentHex || "#0a84ff");
          </script>
        </body>
        </html>

        """,
        "index.css": """
        :root { --sd-accent: #0a84ff; }
        html, body { margin: 0; padding: 0; background: transparent; }
        body { font-family: -apple-system, "SF Pro Text", system-ui, sans-serif; color: #f5f5f7; }
        body[data-theme="light"] { color: #1d1d1f; }
        .card {
          padding: 10px 14px;
          background: color-mix(in oklab, var(--sd-accent) 18%, transparent);
          backdrop-filter: blur(20px);
          border-radius: 10px;
        }
        .title { font-size: 11px; opacity: 0.7; text-transform: uppercase; letter-spacing: 0.05em; }
        .value { font-size: 22px; font-weight: 600; margin-top: 2px; }

        """
    ]

    // MARK: - glass (native LiquidGlass-style material panel)

    private static let glassTemplate: [String: String] = [
        "stack.json": """
        {
          "id": "{{name}}",
          "name": "{{name}}",
          "anchor": { "edge": "top-right", "inset": [16, 16] },
          "size":   { "w": 240, "h": 100 },
          "material": "glass",
          "permissions": ["battery", "appearance"]
        }

        """,
        "index.html": """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><link rel="stylesheet" href="index.css"></head>
        <body>
          <div class="card">
            <div class="title">{{name}}</div>
            <div class="value" id="value">…</div>
          </div>
          <script type="module">
            import { sd } from "sd://runtime/api.js";
            sd.bind(value, sd.battery, b => b ? `${b.percent}% ${b.charging ? "⚡" : ""}` : "…");
            sd.bind([document.body, "data-theme"], sd.appearance, a => a?.dark ? "dark" : "light");
          </script>
        </body>
        </html>

        """,
        "index.css": """
        /* No background on body — let the native NSVisualEffectView material
           show through. CSS backdrop-filter would double-blur. */
        html, body { margin: 0; padding: 0; background: transparent; height: 100%; }
        body { font-family: -apple-system, "SF Pro Text", system-ui, sans-serif; color: #f5f5f7; }
        body[data-theme="light"] { color: #1d1d1f; }
        .card { padding: 14px 18px; }
        .title { font-size: 11px; opacity: 0.7; text-transform: uppercase; letter-spacing: 0.05em; }
        .value { font-size: 32px; font-weight: 600; margin-top: 6px; }

        """
    ]

    // MARK: - menubar (NSStatusItem widget — invisible WebView, visible menu-bar icon)

    private static let menubarTemplate: [String: String] = [
        "stack.json": """
        {
          "id": "{{name}}",
          "name": "{{name}}",
          "anchor": { "edge": "top-left", "inset": [16, 16] },
          "size": { "w": 1, "h": 1 },
          "clickThrough": true,
          "permissions": ["menubar.item", "battery"]
        }

        """,
        "index.html": """
        <!doctype html>
        <html><head><meta charset="utf-8"></head><body>
        <script type="module">
          import { sd } from "sd://runtime/api.js";
          const item = await sd.menubar.addItem({
            icon:    { sfSymbol: "battery.100" },
            tooltip: "{{name}}",
            menu: [
              { id: "hello", title: "Say hello" },
              { separator: true },
              { id: "quit",  title: "Remove this item" }
            ],
            onMenuPick: (pickId) => {
              if (pickId === "hello") item.setTitle("hi");
              if (pickId === "quit")  item.remove();
              setTimeout(() => item.setTitle(""), 1200);
            }
          });
          // Live-update the icon as battery changes.
          sd.battery.subscribe(b => {
            if (!b || b.percent < 0) return;
            const sym = b.percent > 75 ? "battery.100" :
                        b.percent > 50 ? "battery.75"  :
                        b.percent > 25 ? "battery.50"  :
                        b.percent > 10 ? "battery.25"  : "battery.0";
            item.setIcon({ sfSymbol: sym });
          });
        </script>
        </body></html>

        """
    ]

    // MARK: - hud (full-bleed transparent overlay)

    private static let hudTemplate: [String: String] = [
        "stack.json": """
        {
          "id": "{{name}}",
          "name": "{{name}}",
          "region": "fullscreen",
          "size": { "h": 0 },
          "clickThrough": true,
          "permissions": ["mouse", "appearance"]
        }

        """,
        "index.html": """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><link rel="stylesheet" href="index.css"></head>
        <body>
          <div id="dot"></div>
          <script type="module">
            import { sd } from "sd://runtime/api.js";
            sd.bind([dot, "style.--x"], sd.mouse, m => m ? m.x + "px" : "0px");
            sd.bind([dot, "style.--y"], sd.mouse, m => m ? m.y + "px" : "0px");
          </script>
        </body>
        </html>

        """,
        "index.css": """
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        #dot {
          position: absolute;
          left: var(--x, 0); top: var(--y, 0);
          width: 20px; height: 20px; margin: -10px 0 0 -10px;
          border-radius: 10px;
          background: rgba(255, 50, 50, 0.6);
          pointer-events: none;
        }

        """
    ]
}

/// Lightweight manifest validator used by `stackd doctor`. Walks each
/// stack directory, parses its `stack.json`, and prints structured
/// diagnostics. Doesn't run any daemon code — purely static checks.
enum StackDoctor {
    /// Returns the number of issues found in this stack.
    static func check(stackDir: String) -> Int {
        let dirName = (stackDir as NSString).lastPathComponent
        let manifestPath = stackDir + "/stack.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)) else {
            print("❌ \(dirName): missing stack.json at \(manifestPath)")
            return 1
        }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) }
        catch {
            print("❌ \(dirName): stack.json failed to parse — \(error.localizedDescription)")
            return 1
        }
        guard let dict = raw as? [String: Any] else {
            print("❌ \(dirName): stack.json root must be an object, got \(type(of: raw))")
            return 1
        }

        var issues = 0
        func require(_ key: String) {
            if dict[key] == nil { print("❌ \(dirName): missing required field '\(key)'"); issues += 1 }
        }
        require("id")
        require("name")
        require("size")

        if let id = dict["id"] as? String, id != dirName {
            print("⚠️  \(dirName): id is '\(id)' but folder is '\(dirName)' — these usually match")
        }

        if let perms = dict["permissions"] as? [String] {
            let known: Set<String> = [
                "battery", "mouse", "appearance", "input", "net", "audio", "display",
                "media", "settings", "fs", "pasteboard", "proc", "events", "apps",
                "icons", "ax", "windows", "spaces", "menubar", "menubar.item", "menu",
                "app", "defaults", "caffeinate", "notify", "location", "usb",
                "camera", "broadcasts", "host", "applescript", "sound", "nlp",
                "touchdevice", "displayLink", "httpserver", "vision", "sqlite",
                "cursor", "overlay", "shortcuts"
            ]
            for p in perms where !known.contains(p) {
                print("⚠️  \(dirName): unknown permission '\(p)' — typo? Known: \(known.sorted().joined(separator: ", "))")
                issues += 1
            }
        } else if dict["permissions"] != nil {
            print("❌ \(dirName): 'permissions' must be a string array, got \(type(of: dict["permissions"]!))")
            issues += 1
        }

        if !FileManager.default.fileExists(atPath: stackDir + "/index.html") {
            print("⚠️  \(dirName): no index.html — stack will load nothing")
            issues += 1
        }

        if issues == 0 { print("✓  \(dirName)") }
        return issues
    }
}
