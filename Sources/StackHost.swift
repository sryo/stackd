import AppKit

struct StackManifest: Decodable {
    let id: String
    let name: String
    let anchor: Anchor?
    let region: String?             // "menubar" — overrides anchor, spans screen width
    let size: Size
    let clickThrough: Bool?
    let permissions: [String]
    let hotkeys: [Hotkey]?
    let handles: [String]?          // bangs this stack handles
    let eventtap: [EventTap]?
    let display: String?            // "primary" (default) | "all" | "<index>"

    struct Anchor: Decodable { let edge: String; let inset: [Int] }
    struct Size: Decodable { let w: Int?; let h: Int }
    struct Hotkey: Decodable { let key: String; let callback: String }
    struct EventTap: Decodable { let event: String; let callback: String }
}

final class StackHost {
    let rootPath: String
    let schemeHandler: StackdSchemeHandler
    var windows: [String: StackWindow] = [:]
    var bridges: [String: Bridge] = [:]
    private var defaults: [String: Any] = [:]

    init(rootPath: String, runtimePath: String) {
        self.rootPath = rootPath
        self.schemeHandler = StackdSchemeHandler(runtimePath: runtimePath)
    }

    private func loadDefaults() {
        defaults = [:]
        let path = rootPath + "/defaults.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        defaults = dict
        log("loaded defaults.json (\(dict.count) keys)")
    }

    // MARK: - Discovery & reload

    func discoverAndLoad() {
        loadDefaults()
        let stacksDir = rootPath + "/stacks"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stacksDir) else {
            log("no stacks dir at \(stacksDir)")
            return
        }
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let path = stacksDir + "/" + entry
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                loadStack(at: path)
            }
        }
    }

    func reloadAll() {
        unloadAll()
        discoverAndLoad()
    }

    func unloadAll() {
        for win in windows.values {
            win.orderOut(nil)
            win.close()
        }
        windows.removeAll()
        bridges.removeAll()
        schemeHandler.clearRegistrations()
        HotkeyRegistry.shared.unbindAll()
        EventTapRegistry.shared.unregisterAll()
        WorkspaceObserver.shared.unsubscribeAll()
        AppearanceObserver.shared.unsubscribeAll()
        InputObserver.shared.unsubscribeAll()
        NetworkObserver.shared.unsubscribeAll()
        AudioObserver.shared.unsubscribeAll()
        DisplayObserver.shared.unsubscribeAll()
        MediaObserver.shared.unsubscribeAll()
        PasteboardObserver.shared.unsubscribeAll()
        MenuBarVisibility.resetForReload()
    }

    // MARK: - CLI ops

    func listStacks() -> [String] {
        return Array(windows.keys).sorted()
    }

    @discardableResult
    func setCSS(stackId: String, property: String, value: String) -> Bool {
        // Match exact key first; otherwise fan out to all per-display instances
        // sharing the base id (keys formatted "<id>@<N>" when display is "all").
        var keys: [String] = []
        if windows[stackId] != nil {
            keys = [stackId]
        } else {
            let prefix = stackId + "@"
            keys = windows.keys.filter { $0.hasPrefix(prefix) }.sorted()
        }
        guard !keys.isEmpty else { return false }
        let p = property.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let v = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let js = "document.documentElement.style.setProperty(\"\(p)\", \"\(v)\");"
        for k in keys {
            guard let win = windows[k] else { continue }
            DispatchQueue.main.async { win.webView.evaluateJavaScript(js, completionHandler: nil) }
        }
        return true
    }

    @discardableResult
    func bang(name: String, detail: [String: String]) -> Int {
        var fired = 0
        for bridge in bridges.values where bridge.handles(bang: name) {
            bridge.fireBang(name: name, detail: detail)
            fired += 1
        }
        return fired
    }

    // MARK: - Load one stack

    func loadStack(at path: String) {
        let url = URL(fileURLWithPath: path)
        let manifestURL = url.appendingPathComponent("stack.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            log("missing manifest at \(manifestURL.path)"); return
        }
        let manifest: StackManifest
        do {
            let raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            var merged = defaults
            for (k, v) in raw { merged[k] = v }
            let mergedData = try JSONSerialization.data(withJSONObject: merged)
            manifest = try JSONDecoder().decode(StackManifest.self, from: mergedData)
        } catch {
            log("bad manifest \(manifestURL.path): \(error)"); return
        }

        schemeHandler.register(stackId: manifest.id, rootURL: url)

        let targets = StackHost.screensFor(displaySpec: manifest.display ?? "primary")
        guard !targets.isEmpty else {
            log("stack \(manifest.id) — no matching displays for spec=\(manifest.display ?? "primary")")
            return
        }

        for (i, screen) in targets {
            let key = (targets.count == 1) ? manifest.id : "\(manifest.id)@\(i)"
            spawnInstance(manifest: manifest, key: key, screen: screen)
        }
    }

    private func spawnInstance(manifest: StackManifest, key: String, screen: NSScreen) {
        let frame = frameFor(manifest: manifest, screen: screen)

        // Default HUDs sit at .statusBar (25), below the macOS menu bar which
        // composites at a higher visual level. region:"menubar" needs to draw
        // OVER the menu bar — bump to .screenSaver (1000), same trick
        // SketchyBar uses.
        let level: NSWindow.Level = manifest.region == "menubar" ? .screenSaver : .statusBar
        let win = StackWindow(
            frame: frame,
            clickThrough: manifest.clickThrough ?? true,
            schemeHandler: schemeHandler,
            level: level
        )
        let bridge = Bridge(webView: win.webView)
        bridge.start(manifest: manifest)
        bridges[key] = bridge

        let entry = URL(string: "sd://\(manifest.id)/index.html")!
        win.webView.load(URLRequest(url: entry))
        win.orderFrontRegardless()
        windows[key] = win
    }

    /// Compute the on-screen frame for a stack, honoring `region:` overrides
    /// (currently only "menubar") and otherwise falling back to anchor/inset.
    private func frameFor(manifest: StackManifest, screen: NSScreen) -> NSRect {
        let h = CGFloat(manifest.size.h)

        if manifest.region == "menubar" {
            // Full-bleed top bar that covers the system menu bar. screen.frame
            // includes the menu-bar region; visibleFrame excludes it. The menu
            // bar's actual height varies (24 on classic Macs, ~39 on notched
            // MBPs, 57 on "More Space" scaling) — auto-grow to cover it if the
            // manifest height is smaller.
            let full = screen.frame
            let menuBarHeight = full.size.height - screen.visibleFrame.size.height
            let height = max(h, menuBarHeight)
            return NSRect(x: full.minX, y: full.maxY - height, width: full.size.width, height: height)
        }

        let vf = screen.visibleFrame
        let w = CGFloat(manifest.size.w ?? Int(vf.width))
        let anchor = manifest.anchor ?? StackManifest.Anchor(edge: "top-right", inset: [16, 16])
        let insetY = CGFloat(anchor.inset.indices.contains(0) ? anchor.inset[0] : 16)
        let insetX = CGFloat(anchor.inset.indices.contains(1) ? anchor.inset[1] : 16)

        switch anchor.edge {
        case "top-right":    return NSRect(x: vf.maxX - w - insetX, y: vf.maxY - h - insetY, width: w, height: h)
        case "top-left":     return NSRect(x: vf.minX + insetX,     y: vf.maxY - h - insetY, width: w, height: h)
        case "bottom-right": return NSRect(x: vf.maxX - w - insetX, y: vf.minY + insetY,     width: w, height: h)
        case "bottom-left":  return NSRect(x: vf.minX + insetX,     y: vf.minY + insetY,     width: w, height: h)
        default:             return NSRect(x: vf.midX - w/2,        y: vf.midY - h/2,        width: w, height: h)
        }
    }

    private static func screensFor(displaySpec: String) -> [(Int, NSScreen)] {
        let all = NSScreen.screens
        switch displaySpec {
        case "primary":
            return all.first.map { [(0, $0)] } ?? []
        case "all":
            return all.enumerated().map { ($0.offset, $0.element) }
        default:
            if let idx = Int(displaySpec), all.indices.contains(idx) {
                return [(idx, all[idx])]
            }
            return []
        }
    }
}
