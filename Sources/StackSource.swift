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
/// references and return the set of permissions implied. Covers both
/// read-only channels (sd.battery, sd.windows.focused, …) and RPC
/// namespaces that map identity-to-permission (sd.fs.*, sd.proc.*, …) so
/// authors don't have to repeat the manifest list.
///
/// Top-level identity inference is preferred over sub-path entries because
/// most permissions name their entire `sd.<perm>.*` namespace (no
/// ambiguity). The boundary-aware scanner prevents false positives —
/// `sd.applescript.run` does NOT trigger "app" because the prev/next-char
/// check rejects partial-identifier matches.
///
/// Composite permissions (`menubar.item`) stay explicit and are NOT
/// inferred — they carry stricter side-effects than the base namespace and
/// should require visible opt-in.
enum ChannelInference {
    /// Permissions inferred by identity match — `sd.<name>.*` anywhere in
    /// the source implies the permission. Includes every single-token
    /// permission in the StackDoctor allowlist. Drop here when adding a
    /// new identity-named permission; composites stay out.
    private static let topLevelChannels: [String] = [
        // Read-only channel signals
        "battery", "mouse", "appearance", "caffeinate",
        "sensors", "location", "usb", "camera", "touchdevice", "displayLink",
        // Composite top-level (RPC + channel under one namespace)
        "app", "windows", "input", "net", "audio", "display", "media",
        "pasteboard", "apps", "spaces", "host", "calendar", "menubar", "privacy",
        // Pure RPC namespaces — identity-named permission
        "fs", "proc", "applescript", "notify", "settings", "defaults",
        "broadcasts", "ax", "spotlight", "speech", "vision", "nlp", "bonjour",
        "httpserver", "sqlite", "update", "cursor", "overlay", "shortcuts",
        "sound", "icons", "thumbnails", "events", "menu"
    ]

    /// Sub-path entries are kept as an extension hook for permissions whose
    /// name doesn't match their `sd.` namespace (today: none — composite
    /// permissions like `menubar.item` are intentionally NOT inferred and
    /// require explicit manifest opt-in).
    private static let subPathChannels: [String: String] = [:]

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
