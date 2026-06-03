import AppKit

struct StackManifest: Decodable {
    let id: String
    let name: String
    let anchor: Anchor?
    let region: String?             // "menubar" — overrides anchor, spans screen width
    let size: Size
    let clickThrough: Bool?
    // Mutable so StackHost can merge auto-inferred channel permissions
    // (scanned from the stack's source) before passing to Bridge.start.
    var permissions: [String]
    let hotkeys: [Hotkey]?
    let handles: [String]?          // bangs this stack handles
    let eventtap: [EventTap]?
    let display: String?            // "primary" (default) | "all" | "<index>"
    let invocable: Bool?            // window starts hidden + can take key on .invoke()
    let level: String?              // semantic tier or numeric override — see resolveLevel below
    /// Unified material model — see `StackMaterial`. Accepted forms:
    ///   - missing / null / "none" → no backing
    ///   - "vibrancy.<key>" or legacy bare key ("sidebar", "hud", "popover",
    ///     "menu", "titlebar", "sheet", "window", "header", "selection") →
    ///     NSVisualEffectView
    ///   - "glass" / "glass.clear" / "glass.tinted(#RRGGBB)" → NSGlassEffectView
    ///     on macOS 26+, falls back to vibrancy.hudWindow on older OSes.
    let material: String?
    /// Optional corner radius applied to the WebView (and the material layer
    /// when one is installed). Applies regardless of `material`. Ignored when
    /// `shape == "capsule"` — capsule derives its radius from min(w,h)/2.
    let cornerRadius: Double?
    /// Outer shape of the material backing. `"rect"` (default) honors
    /// `cornerRadius`; `"capsule"` produces a pill (or circle when w==h),
    /// ignoring `cornerRadius`. See `StackShape` for the resolution rule.
    let shape: String?
    /// Inner inset between the material edge and the WebView, in points.
    /// Default 0 (WebView fills the material). When > 0, the WebView's
    /// corners are auto-computed to stay CONCENTRIC with the outer material
    /// edge (mirrors SwiftUI's `RoundedRectangularShapeCorners.concentric`).
    let padding: Double?

    struct Anchor: Decodable { let edge: String; let inset: [Int] }
    struct Size: Decodable { let w: Int?; let h: Int }
    /// `key` is the chord (`"cmd+shift+l"`, `"cmd+alt+ctrl+shift+a"`, …). `mode` gates
    /// dispatch on the active HotkeyRegistry mode (skhd-style modal keymaps;
    /// nil means always-on). `apps` gates on the frontmost app's bundleID
    /// (nil = ungated; element `"*"` = any).
    struct Hotkey: Decodable {
        let key: String
        let callback: String
        let mode: String?
        let apps: [String]?
        let excludeApps: [String]?
    }
    /// `consume: true` migrates this entry to the consuming CGEventTap. The
    /// `if` predicate is evaluated synchronously inside the tap callback —
    /// JS round-tripping per-event would force CG to wait on WKWebView. An
    /// empty/missing `if` means "consume every event of this type" (useful
    /// for the demo case but rarely what you want in production).
    ///
    /// `requireRects: true` defaults the cursor-rect gate to an empty array
    /// at registration so the consumer never matches until JS has called
    /// `sd.events.setTapRects(callback, [...])`. Closes the boot race window
    /// where the consumer is live but JS hasn't yet pushed rects — without
    /// this flag the consumer's empty predicate matches every event of the
    /// type, eating every click between stack-load and JS-ready.
    struct EventTap: Decodable {
        let event: String
        let callback: String
        let consume: Bool?
        let requireRects: Bool?
        let `if`: Predicate?

        struct Predicate: Decodable {
            let keyCode: Int?
            let keyCodes: [Int]?
            let flagsMask: UInt64?
            let flagsAny: UInt64?
        }
    }
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
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if let src = StackSource.loadFolder(at: path, defaults: defaults) {
                loadStack(source: src)
            }
        }
    }

    func reloadAll() {
        unloadAll()
        discoverAndLoad()
    }

    func unloadAll() {
        // Each Bridge owns a StackScope; draining it releases all native
        // resources (observer subscriptions, hotkeys, eventtaps, menubar
        // suppressions, future AX observers). Belt-and-suspenders menubar
        // reset covers the rare case where every stack crashed mid-suppress.
        for id in Array(bridges.keys) { unloadStack(id: id) }
        schemeHandler.clearRegistrations()
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
        let folder = rootPath + "/stacks/\(id)"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir),
              isDir.boolValue,
              let src = StackSource.loadFolder(at: folder, defaults: defaults)
        else { return "error: no stack named '\(id)'\n" }
        loadStack(source: src)
        return "enabled \(id)\n"
    }

    private func unloadStack(id: String) {
        if let win = windows[id] {
            // Tell JS to clean up DOM state before the WebView is torn down.
            // sd.bind doesn't strictly need this (subscriptions die with the
            // WebView), but stacks can listen for `stackd:unload` to save
            // state, log, or release things outside the page lifecycle.
            win.webView.evaluateJavaScript(
                "window.dispatchEvent(new Event('stackd:unload'))",
                completionHandler: nil
            )
            win.orderOut(nil)
            win.close()
            windows.removeValue(forKey: id)
        }
        // Drain native resources (observer subs, hotkeys, eventtaps, menubar
        // suppressions) BEFORE dropping the Bridge — the Token cancel closures
        // reference back into shared registries, not into Bridge itself.
        bridges[id]?.scope.drain()
        bridges.removeValue(forKey: id)
        schemeHandler.unregister(stackId: id)
    }

    private func unloadAllInstances(baseId: String) {
        let keys = windows.keys.filter { $0 == baseId || $0.hasPrefix(baseId + "@") }
        for k in keys {
            windows[k]?.webView.evaluateJavaScript(
                "window.dispatchEvent(new Event('stackd:unload'))",
                completionHandler: nil
            )
            windows[k]?.orderOut(nil)
            windows[k]?.close()
            windows.removeValue(forKey: k)
            bridges[k]?.scope.drain()
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

    private func loadStack(source: StackSource) {
        // Channels-only auto-permission merge. RPC actions (fs.*, proc,
        // hotkey.bind, …) still require explicit manifest declaration —
        // they carry real security implications and shouldn't be granted
        // just because the stack source contains the string.
        var manifest = source.manifest
        let inferred = ChannelInference.infer(from: source.sourceText)
        let added = inferred.subtracting(manifest.permissions).sorted()
        if !added.isEmpty {
            manifest.permissions += added
            log("stack \(manifest.id) — inferred channels: \(added.joined(separator: ", "))")
        }

        schemeHandler.register(stackId: manifest.id, rootURL: source.rootURL)

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

        let invocable = manifest.invocable ?? false
        let level = StackHost.resolveLevel(manifest: manifest)
        let resolvedMaterial = StackMaterial.parse(manifest.material)
        let resolvedRadius = StackCornerRadius.parse(manifest.cornerRadius)
        let resolvedPadding = StackPadding.effectivePadding(
            manifest: manifest.padding,
            material: resolvedMaterial,
            cornerRadius: resolvedRadius)
        let win = StackWindow(
            frame: frame,
            clickThrough: invocable ? false : (manifest.clickThrough ?? true),
            schemeHandler: schemeHandler,
            level: level,
            invocable: invocable,
            material: resolvedMaterial,
            cornerRadius: resolvedRadius,
            shape: StackShape.parse(manifest.shape)
        )
        let bridge = Bridge(webView: win.webView, screen: screen, screenIndex: screenIndex, padding: resolvedPadding)
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
            // includes the menu-bar region; visibleFrame excludes it.
            //
            // Sizing modes:
            //   size.h == 0 (or unset) → exactly match THIS display's menubar
            //     height. With "display": "all" + multi-monitor (notched
            //     MacBook + external), each instance is sized per-display
            //     (~39px notched, ~24px standard, ~57px "More Space" mode).
            //   size.h > 0 → max(h, menuBarHeight) — legacy behavior, keeps
            //     stacks that want a guaranteed minimum unaffected.
            let full = screen.frame
            let menuBarHeight = full.size.height - screen.visibleFrame.size.height
            let height = h > 0 ? max(h, menuBarHeight) : menuBarHeight
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
        return StackHost.anchorRect(edge: anchor.edge, w: w, h: h, insetX: insetX, insetY: insetY, visibleFrame: vf)
    }

    /// Resolve a non-fullscreen, non-menubar anchor edge into a frame rect.
    /// Pure function — extracted from `frameFor` so the geometry can be
    /// unit-tested without instantiating NSScreen / StackManifest. The set
    /// of recognized edge keys lives entirely in this switch.
    ///
    /// Edge taxonomy:
    /// - Corner anchors (`top-right`, `top-left`, `bottom-right`, `bottom-left`):
    ///   manifest size used as-is, inset offsets from the corner.
    /// - Horizontal-center anchors (`top-center`, `bottom-center`): manifest
    ///   width used as-is, centered on midX; insetY offsets from the matching
    ///   edge. Used by floating bottom HUDs (SideSwipe), top toast strips, etc.
    /// - Full-bleed edge anchors (`top`, `bottom`, `left`, `right`): stretch
    ///   across the visible frame, manifest size is the THICKNESS only.
    /// - Unknown → center of the visible frame.
    static func anchorRect(edge: String, w: CGFloat, h: CGFloat, insetX: CGFloat, insetY: CGFloat, visibleFrame vf: NSRect) -> NSRect {
        switch edge {
        case "top-right":     return NSRect(x: vf.maxX - w - insetX, y: vf.maxY - h - insetY, width: w, height: h)
        case "top-left":      return NSRect(x: vf.minX + insetX,     y: vf.maxY - h - insetY, width: w, height: h)
        case "bottom-right":  return NSRect(x: vf.maxX - w - insetX, y: vf.minY + insetY,     width: w, height: h)
        case "bottom-left":   return NSRect(x: vf.minX + insetX,     y: vf.minY + insetY,     width: w, height: h)
        case "top-center":    return NSRect(x: vf.midX - w/2,        y: vf.maxY - h - insetY, width: w, height: h)
        case "bottom-center": return NSRect(x: vf.midX - w/2,        y: vf.minY + insetY,     width: w, height: h)
        case "top":           return NSRect(x: vf.minX,              y: vf.maxY - h,          width: vf.width, height: h)
        case "bottom":        return NSRect(x: vf.minX,              y: vf.minY,              width: vf.width, height: h)
        case "left":          return NSRect(x: vf.minX,              y: vf.minY,              width: w,        height: vf.height)
        case "right":         return NSRect(x: vf.maxX - w,          y: vf.minY,              width: w,        height: vf.height)
        default:              return NSRect(x: vf.midX - w/2,        y: vf.midY - h/2,        width: w,        height: h)
        }
    }

    /// Resolve the per-stack window level. Semantic tiers ascending:
    ///   "bar"     900 — topbars / menubar replacements (above ordinary windows,
    ///                    below HUDs so tooltips render on top of the bar)
    ///   "overlay" 950 — default for HUDs (toasts, badges, frame outlines)
    ///   "tooltip" 1000 — hover hints that should sit on top of overlays
    ///                    (FrameMaster corner labels, dock-style indicators)
    ///   "cursor"  1050 — cursor-anchored layers that must beat everything
    ///                    else (TimeTrail trail, BubbleCursor)
    /// A numeric string (e.g. "1234") overrides the tier table. Legacy
    /// "high" maps to 999 for compatibility. Default with no level field:
    /// "bar" if region == "menubar" (otherwise the bar would render below
    /// the system menubar), "overlay" otherwise.
    static func resolveLevel(manifest: StackManifest) -> NSWindow.Level {
        if let s = manifest.level, !s.isEmpty {
            if let n = Int(s) { return NSWindow.Level(rawValue: n) }
            switch s {
            case "bar":     return NSWindow.Level(rawValue: 900)
            case "overlay": return NSWindow.Level(rawValue: 950)
            case "tooltip": return NSWindow.Level(rawValue: 1000)
            case "cursor":  return NSWindow.Level(rawValue: 1050)
            case "high":    return NSWindow.Level(rawValue: 999) // legacy
            default: break
            }
        }
        if manifest.region == "menubar" { return NSWindow.Level(rawValue: 900) }
        return NSWindow.Level(rawValue: 950)
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
