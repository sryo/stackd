import Foundation

/// On-disk stack loaded from `~/stackd/stacks/<id>/`: a folder containing
/// `stack.json` + `index.html` + assets. URLSchemeHandler serves files
/// directly off `rootURL`.
///
/// `sourceText` is the concatenation of every text asset the stack ships
/// (HTML + CSS + JS). Used by `ChannelInference.infer` to scan for
/// `sd.<channel>` references so the manifest's `permissions` list can be
/// auto-augmented — channels-only; RPC permissions still require explicit
/// declaration.
struct StackSource {
    let manifest: StackManifest
    let rootURL: URL
    let sourceText: String  // everything we scan for sd.<channel> references

    /// Load `~/stackd/stacks/<id>/`. Returns nil on bad manifest.
    static func loadFolder(at path: String, defaults: [String: Any]) -> StackSource? {
        let url = URL(fileURLWithPath: path)
        let manifestURL = url.appendingPathComponent("stack.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            log("missing manifest at \(manifestURL.path)"); return nil
        }
        let manifest: StackManifest
        do {
            let raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            var merged = defaults
            for (k, v) in raw { merged[k] = v }
            let mergedData = try JSONSerialization.data(withJSONObject: merged)
            manifest = try JSONDecoder().decode(StackManifest.self, from: mergedData)
        } catch {
            log("bad manifest \(manifestURL.path): \(error)"); return nil
        }

        // Scan every text asset in the stack dir so an inferred permission
        // works whether the channel reference lives in index.html, index.css
        // (via something like `attr(data-pct) px` patterns), or a separate
        // .js module imported by the stack.
        let scanExts: Set<String> = ["html", "htm", "css", "js", "mjs"]
        var combined = ""
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for entry in entries {
                let ext = (entry as NSString).pathExtension.lowercased()
                guard scanExts.contains(ext) else { continue }
                let p = path + "/" + entry
                if let s = try? String(contentsOfFile: p, encoding: .utf8) {
                    combined += s + "\n"
                }
            }
        }
        return StackSource(
            manifest: manifest,
            rootURL: url,
            sourceText: combined
        )
    }
}

// MARK: - Channel inference

/// Channel-permission inference: scan a stack's source text for `sd.<path>`
/// references and return the set of channel permissions implied. Pure
/// channels only — RPC actions (fs.*, proc.exec, hotkey.bind, etc.) keep
/// their explicit declarations because they have real side-effects.
///
/// The mapping is intentionally hardcoded here rather than derived from the
/// runtime: the JS-side `sd` proxy is dynamic and a regex can't tell
/// `sd.audio.output` (channel) from `sd.audio.setVolume(...)` (RPC) without
/// this list. Match the table in StackHost docs / the task description.
enum ChannelInference {
    /// Channels that map 1:1 to a top-level `sd.<name>`. The presence of
    /// `sd.battery`, `sd.mouse`, `sd.appearance`, etc. anywhere in the
    /// source implies the corresponding permission.
    private static let topLevelChannels: [String] = [
        "battery", "mouse", "appearance", "caffeinate",
        "sensors", "location", "usb", "camera", "touchdevice", "displayLink"
    ]

    /// Channels whose permission name differs from the `sd.` prefix, or where
    /// only specific sub-paths count as channels. Map each sub-path to the
    /// permission to enable. Sub-path keys are the FULL path after `sd.`
    /// (e.g. "app.frontmost"); presence of `sd.app.frontmost` implies "app".
    private static let subPathChannels: [String: String] = [
        "app.frontmost":     "app",
        "app.activated":     "app",
        "windows.focused":   "windows",
        "windows.focusedChanged": "windows",
        "windows.titleChanged":   "windows",
        "windows.all":       "windows",
        "input.layout":      "input",
        "net.wifi":          "net",
        "net.lan":           "net",
        "net.path":          "net",
        "net.throughput":    "net",
        "audio.output":      "audio",
        "audio.input":       "audio",
        "display.all":       "display",
        "media.nowPlaying":  "media",
        "pasteboard.changed":"pasteboard",
        "apps.running":      "apps",
        "apps.changed":      "apps",
        "spaces.all":        "spaces",
        "host.load":         "host",
        "host.info":         "host",
        "host.diskIO":       "host",
        "calendar.observe":  "calendar",
        "menubar.observe":   "menubar",
        "privacy.observe":   "privacy"
    ]

    /// Scan `text` (an HTML/JS/CSS source blob) for sd-channel references
    /// and return the implied permission set. Matches both `{{ sd.x.y }}`
    /// template expressions and `sd.x.y.subscribe(...)` / `sd.bind(_, sd.x, …)`
    /// JS usage — they share the same `sd.<path>` prefix shape.
    static func infer(from text: String) -> Set<String> {
        var out = Set<String>()
        for ch in topLevelChannels {
            if containsReference(text, path: ch) { out.insert(ch) }
        }
        for (subPath, perm) in subPathChannels {
            if containsReference(text, path: subPath) { out.insert(perm) }
        }
        return out
    }

    /// True if `text` contains `sd.<path>` as an actual reference (not a
    /// substring of a longer identifier). Uses a manual scan because
    /// NSRegularExpression with `\b` doesn't treat `.` as a word boundary
    /// the way we want and the alternative (full character-class lookbehind)
    /// is more code than this loop.
    private static func containsReference(_ text: String, path: String) -> Bool {
        let needle = "sd." + path
        let chars = Array(text)
        let nchars = Array(needle)
        guard chars.count >= nchars.count else { return false }
        let maxI = chars.count - nchars.count
        var i = 0
        while i <= maxI {
            // Left boundary: previous char must not be a continuation of an
            // identifier (letter/digit/_/$/.). Prevents `xsd.battery` or
            // `notsd.battery` from matching.
            if i > 0 {
                let prev = chars[i - 1]
                if prev.isLetter || prev.isNumber || prev == "_" || prev == "$" || prev == "." {
                    i += 1; continue
                }
            }
            var match = true
            for j in 0..<nchars.count where chars[i + j] != nchars[j] {
                match = false; break
            }
            if match {
                // Right boundary: next char (if any) must not continue the
                // identifier. Lets `sd.battery.percent` match the "battery"
                // top-level while `sd.batteryFoo` does not.
                let after = i + nchars.count
                if after >= chars.count {
                    return true
                }
                let next = chars[after]
                if !(next.isLetter || next.isNumber || next == "_" || next == "$") {
                    return true
                }
            }
            i += 1
        }
        return false
    }
}
