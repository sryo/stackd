import AppKit

struct StackManifest: Decodable {
    let id: String
    let name: String
    let anchor: Anchor
    let size: Size
    let clickThrough: Bool?
    let permissions: [String]
    let hotkeys: [Hotkey]?
    let handles: [String]?          // bangs this stack handles
    let eventtap: [EventTap]?
    let display: String?            // "primary" (default) | "all" | "<index>"

    struct Anchor: Decodable { let edge: String; let inset: [Int] }
    struct Size: Decodable { let w: Int; let h: Int }
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
        let vf = screen.visibleFrame
        let w = CGFloat(manifest.size.w)
        let h = CGFloat(manifest.size.h)
        let insetY = CGFloat(manifest.anchor.inset.indices.contains(0) ? manifest.anchor.inset[0] : 16)
        let insetX = CGFloat(manifest.anchor.inset.indices.contains(1) ? manifest.anchor.inset[1] : 16)

        let frame: NSRect
        switch manifest.anchor.edge {
        case "top-right":
            frame = NSRect(x: vf.maxX - w - insetX, y: vf.maxY - h - insetY, width: w, height: h)
        case "top-left":
            frame = NSRect(x: vf.minX + insetX, y: vf.maxY - h - insetY, width: w, height: h)
        case "bottom-right":
            frame = NSRect(x: vf.maxX - w - insetX, y: vf.minY + insetY, width: w, height: h)
        case "bottom-left":
            frame = NSRect(x: vf.minX + insetX, y: vf.minY + insetY, width: w, height: h)
        default:
            frame = NSRect(x: vf.midX - w/2, y: vf.midY - h/2, width: w, height: h)
        }

        let win = StackWindow(
            frame: frame,
            clickThrough: manifest.clickThrough ?? true,
            schemeHandler: schemeHandler
        )
        let bridge = Bridge(webView: win.webView)
        bridge.start(manifest: manifest)
        bridges[key] = bridge

        let entry = URL(string: "sd://\(manifest.id)/index.html")!
        win.webView.load(URLRequest(url: entry))
        win.orderFrontRegardless()
        windows[key] = win
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
