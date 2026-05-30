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
    let invocable: Bool?            // window starts hidden + can take key on .invoke()
    let level: String?              // "high" → above default .statusBar (for toasts on fullscreen stacks)

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
        AppsObserver.shared.unsubscribeAll()
        SpacesObserver.shared.unsubscribeAll()
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

    /// Enable/disable a single stack by id. If currently loaded, unload it
    /// (without disturbing the rest). If unloaded but a stacks/<id>/ folder
    /// exists, load it. Returns a human-readable result line for the CLI.
    func toggle(id: String) -> String {
        if windows[id] != nil {
            unloadStack(id: id)
            return "disabled \(id)\n"
        }
        let prefix = id + "@"
        if let multiKey = windows.keys.first(where: { $0.hasPrefix(prefix) }) {
            let baseId = String(multiKey.split(separator: "@").first ?? "")
            unloadAllInstances(baseId: baseId)
            return "disabled \(id) (was multi-display)\n"
        }
        let path = rootPath + "/stacks/\(id)"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            loadStack(at: path)
            return "enabled \(id)\n"
        }
        return "error: no stack named '\(id)'\n"
    }

    private func unloadStack(id: String) {
        if let win = windows[id] {
            win.orderOut(nil)
            win.close()
            windows.removeValue(forKey: id)
        }
        bridges.removeValue(forKey: id)
        schemeHandler.unregister(stackId: id)
    }

    private func unloadAllInstances(baseId: String) {
        let keys = windows.keys.filter { $0 == baseId || $0.hasPrefix(baseId + "@") }
        for k in keys {
            windows[k]?.orderOut(nil)
            windows[k]?.close()
            windows.removeValue(forKey: k)
            bridges.removeValue(forKey: k)
        }
        schemeHandler.unregister(stackId: baseId)
    }

    @discardableResult
    func bang(name: String, detail: [String: Any]) -> Int {
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
            spawnInstance(manifest: manifest, key: key, screen: screen, screenIndex: i)
        }
    }

    private func spawnInstance(manifest: StackManifest, key: String, screen: NSScreen, screenIndex: Int) {
        let frame = frameFor(manifest: manifest, screen: screen)

        // Default HUDs sit at .statusBar (25), below the macOS menu bar which
        // composites at a higher visual level. region:"menubar" needs to draw
        // OVER the menu bar — bump to .screenSaver (1000), same trick
        // SketchyBar uses. Invocable stacks (palettes / choosers) need to
        // take key, which a click-through HUD can't.
        let invocable = manifest.invocable ?? false
        // Fullscreen stacks all share level .statusBar, so multiple fullscreens
        // (TimeTrail + UndoClose, future cursor overlays) get z-order set by
        // load order. For HUDs that need to win against ambient fullscreens,
        // manifest can set `level: "high"` to use .screenSaver-1.
        let level: NSWindow.Level = {
            if manifest.region == "menubar" { return .screenSaver }
            if manifest.level == "high"     { return NSWindow.Level(rawValue: 999) }
            return .statusBar
        }()
        let win = StackWindow(
            frame: frame,
            clickThrough: invocable ? false : (manifest.clickThrough ?? true),
            schemeHandler: schemeHandler,
            level: level,
            invocable: invocable
        )
        let bridge = Bridge(webView: win.webView, screen: screen, screenIndex: screenIndex)
        bridge.start(manifest: manifest)
        bridges[key] = bridge

        let entry = URL(string: "sd://\(manifest.id)/index.html")!
        win.webView.load(URLRequest(url: entry))
        // Invocable stacks stay hidden until sd.window.invoke() is called.
        if !invocable {
            win.orderFrontRegardless()
        }
        windows[key] = win
    }

    /// Compute the on-screen frame for a stack, honoring `region:` overrides
    /// (menubar, fullscreen) and otherwise falling back to anchor/inset.
    private func frameFor(manifest: StackManifest, screen: NSScreen) -> NSRect {
        let h = CGFloat(manifest.size.h)

        if manifest.region == "menubar" {
            // Full-bleed top bar that covers the system menu bar. screen.frame
            // includes the menu-bar region; visibleFrame excludes it. Auto-grow
            // to the actual menu bar height (~24 / ~39 notched / 57 "More Space").
            let full = screen.frame
            let menuBarHeight = full.size.height - screen.visibleFrame.size.height
            let height = max(h, menuBarHeight)
            return NSRect(x: full.minX, y: full.maxY - height, width: full.size.width, height: height)
        }

        if manifest.region == "fullscreen" {
            // Entire screen, ignoring menu bar / dock. For cursor-overlay
            // stacks (TimeTrail, BubbleCursor) that need to draw anywhere.
            return screen.frame
        }

        let vf = screen.visibleFrame
        let w = CGFloat(manifest.size.w ?? Int(vf.width))
        let anchor = manifest.anchor ?? StackManifest.Anchor(edge: "top-right", inset: [16, 16])
        let insetY = CGFloat(anchor.inset.indices.contains(0) ? anchor.inset[0] : 16)
        let insetX = CGFloat(anchor.inset.indices.contains(1) ? anchor.inset[1] : 16)

        switch anchor.edge {
        // Corner anchors: size from manifest, offset by inset.
        case "top-right":    return NSRect(x: vf.maxX - w - insetX, y: vf.maxY - h - insetY, width: w, height: h)
        case "top-left":     return NSRect(x: vf.minX + insetX,     y: vf.maxY - h - insetY, width: w, height: h)
        case "bottom-right": return NSRect(x: vf.maxX - w - insetX, y: vf.minY + insetY,     width: w, height: h)
        case "bottom-left":  return NSRect(x: vf.minX + insetX,     y: vf.minY + insetY,     width: w, height: h)
        // Edge anchors: stretch across the visible frame, manifest size is
        // the THICKNESS only (height for top/bottom, width for left/right).
        case "top":          return NSRect(x: vf.minX,              y: vf.maxY - h,          width: vf.width, height: h)
        case "bottom":       return NSRect(x: vf.minX,              y: vf.minY,              width: vf.width, height: h)
        case "left":         return NSRect(x: vf.minX,              y: vf.minY,              width: w,        height: vf.height)
        case "right":        return NSRect(x: vf.maxX - w,          y: vf.minY,              width: w,        height: vf.height)
        default:             return NSRect(x: vf.midX - w/2,        y: vf.midY - h/2,        width: w,        height: h)
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
