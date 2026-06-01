import Foundation

/// Unifies the two on-disk stack shapes the host can load:
///   • Folder format: `~/stackd/stacks/<id>/stack.json` + index.html + assets.
///     `rootURL` is the folder; `bodyHTML` is nil; URLSchemeHandler serves
///     files directly off disk.
///   • Single-file format: `~/stackd/stacks/<id>.stack` — frontmatter +
///     inline HTML/CSS. `rootURL` is nil; `bodyHTML` is the body (possibly
///     auto-wrapped); URLSchemeHandler serves it from memory for index.html.
///
/// `sourceText` is the concatenation of every text asset the stack ships
/// (HTML + CSS + JS for folder stacks, body for .stack files). Used by
/// `inferChannelPermissions` to scan for `sd.<channel>` references so the
/// manifest's `permissions` list can be auto-augmented — channels-only;
/// RPC permissions still require explicit declaration.
struct StackSource {
    let manifest: StackManifest
    let rootURL: URL?       // nil for in-memory .stack files
    let bodyHTML: String?   // nil for folder stacks
    let sourceText: String  // everything we scan for sd.<channel> references

    /// Load `~/stackd/stacks/<id>/` (folder format). Returns nil on bad manifest.
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
            bodyHTML: nil,
            sourceText: combined
        )
    }

    /// Load `~/stackd/stacks/<id>.stack` (single-file format). The id is
    /// derived from the filename so the frontmatter doesn't need to declare
    /// it; `name` defaults to the id; everything else is the same as folder
    /// manifests.
    static func loadSingleFile(at path: String, defaults: [String: Any]) -> StackSource? {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent
        let id = (filename as NSString).deletingPathExtension
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            log("can't read \(path)"); return nil
        }
        let (fmDict, body) = parseFrontmatter(raw)
        // Auto-populate id (always) and name (if absent) so a minimal .stack
        // file is literally frontmatter:[size, anchor] + body. The whole
        // point is that the filename should suffice.
        var merged = defaults
        for (k, v) in fmDict { merged[k] = v }
        merged["id"] = id
        if merged["name"] == nil { merged["name"] = id }
        // permissions defaults to [] so manifests without explicit perms
        // still decode — task 1's inference layer will augment afterwards.
        if merged["permissions"] == nil { merged["permissions"] = [] as [String] }

        let manifest: StackManifest
        do {
            let mergedData = try JSONSerialization.data(withJSONObject: merged)
            manifest = try JSONDecoder().decode(StackManifest.self, from: mergedData)
        } catch {
            log("bad .stack frontmatter in \(path): \(error)"); return nil
        }

        let html = wrapHTMLIfNeeded(body)
        return StackSource(
            manifest: manifest,
            rootURL: nil,
            bodyHTML: html,
            sourceText: body
        )
    }

    /// Split a `.stack` file into (frontmatter dict, body). The frontmatter
    /// is everything between the first two `---` lines at the start of the
    /// file; the body is everything after. Returns ({}, raw) if no
    /// frontmatter delimiters are present (so a body-only .stack file is
    /// still loadable — handy for proof-of-concept stacks).
    private static func parseFrontmatter(_ raw: String) -> ([String: Any], String) {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], raw)
        }
        lines.removeFirst()
        var fmLines: [String] = []
        var bodyStart = -1
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                bodyStart = i + 1
                break
            }
            fmLines.append(line)
        }
        let body = (bodyStart >= 0) ? lines[bodyStart...].joined(separator: "\n") : ""
        let dict = parseFrontmatterBody(fmLines.joined(separator: "\n"))
        return (dict, body)
    }

    /// Parse the frontmatter body. Format is JSON-superset: each top-level
    /// `key: value` line where value is JSON (string, number, bool, array,
    /// object). Keys are unquoted, values are quoted as JSON. This sidesteps
    /// a full YAML parser while keeping the manifest expressible — the same
    /// JSON shapes that work in stack.json (`anchor: { edge: "top-right",
    /// inset: [16, 16] }`, `permissions: ["battery"]`) all work here.
    /// Lines starting with `#` are comments; blank lines are skipped.
    private static func parseFrontmatterBody(_ text: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty || rest.isEmpty { continue }
            out[key] = decodeFrontmatterValue(rest)
        }
        return out
    }

    /// Decode a single frontmatter value. JSON literal first (covers
    /// `{...}`, `[...]`, `"..."`, numbers, booleans); fall back to treating
    /// it as a bare string so `name: My Widget` (the obvious shape) works
    /// without quotes — same affordance every frontmatter syntax provides.
    private static func decodeFrontmatterValue(_ raw: String) -> Any {
        if let data = raw.data(using: .utf8),
           let v = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return v
        }
        return raw
    }

    /// If the body looks like a fragment (no <html>/<body>), wrap it in a
    /// minimal HTML5 shell so the WebView has a real document. The runtime
    /// loader script + sd:// scheme handler still work either way; this is
    /// purely so authors can write `<div>{{ sd.battery.percent }}%</div>`
    /// without ceremony.
    private static func wrapHTMLIfNeeded(_ body: String) -> String {
        let lower = body.lowercased()
        if lower.contains("<!doctype") || lower.contains("<html") {
            return body
        }
        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"></head>
        <body>
        \(body)
        </body>
        </html>
        """
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
        "audio.output":      "audio",
        "display.all":       "display",
        "media.nowPlaying":  "media",
        "pasteboard.changed":"pasteboard",
        "apps.running":      "apps",
        "apps.changed":      "apps",
        "spaces.all":        "spaces",
        "host.load":         "host",
        "host.info":         "host"
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
