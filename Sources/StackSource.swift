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
        // .js module imported by the stack. Walks recursively because
        // structured stacks split source into `modules/`, `assets/`, etc.
        // — a top-level scan would miss every channel referenced only in a
        // submodule (e.g. windowscape's setFrame calls in modules/tiler.js).
        let scanExts: Set<String> = ["html", "htm", "css", "js", "mjs"]
        var combined = ""
        let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        if let walker = walker {
            for case let fileURL as URL in walker {
                let ext = fileURL.pathExtension.lowercased()
                guard scanExts.contains(ext) else { continue }
                if let s = try? String(contentsOf: fileURL, encoding: .utf8) {
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
    /// the source implies the permission. Derived from `Permissions.inferable`
    /// (which is `Permissions.all` minus composites like `menubar.item`).
    /// Composites stay out because they require explicit opt-in — see the
    /// header doc on `Permissions.inferable`.
    private static let topLevelChannels: [String] = Permissions.inferableSorted

    /// Sub-path entries map a runtime helper to the permission it relies on
    /// when the helper's `sd.` path doesn't name it: `sd.gesture.spring`
    /// ticks on sd.displayLink. Composite permissions like `menubar.item`
    /// are intentionally NOT inferred and require explicit manifest opt-in.
    private static let subPathChannels: [String: String] = [
        "gesture.spring": "displayLink",
    ]

    /// Every path the scanner looks for after `sd.`, with the permission it
    /// implies: each top-level permission names itself, each sub-path maps
    /// to the permission its helper relies on.
    private static let candidates: [(path: [Character], permission: String)] =
        topLevelChannels.map { (Array($0), $0) }
        + subPathChannels.map { (Array($0.key), $0.value) }

    /// Scan `text` (an HTML/JS/CSS source blob) for sd-channel references
    /// and return the implied permission set. Matches both `{{ sd.x.y }}`
    /// template expressions and `sd.x.y.subscribe(...)` / `sd.bind(_, sd.x, …)`
    /// JS usage — they share the same `sd.<path>` prefix shape.
    ///
    /// One pass over the text's characters finds every `sd.` that starts a
    /// reference; only those positions are compared against the candidate
    /// paths. Comparison is per `Character`, so a combining mark after a
    /// path's last letter (or before `sd`) belongs to that letter.
    static func infer(from text: String) -> Set<String> {
        let chars = Array(text)
        var out = Set<String>()
        var i = 0
        while i + 3 <= chars.count {
            defer { i += 1 }
            guard chars[i] == "s", chars[i + 1] == "d", chars[i + 2] == "." else { continue }
            // Left boundary: previous char must not be a continuation of an
            // identifier (letter/digit/_/$/.). Prevents `xsd.battery` or
            // `notsd.battery` from matching.
            if i > 0 {
                let prev = chars[i - 1]
                if prev.isLetter || prev.isNumber || prev == "_" || prev == "$" || prev == "." { continue }
            }
            let start = i + 3
            for (path, permission) in candidates where !out.contains(permission) {
                let end = start + path.count
                guard end <= chars.count, chars[start..<end].elementsEqual(path) else { continue }
                // Right boundary: next char (if any) must not continue the
                // identifier. Lets `sd.battery.percent` match the "battery"
                // top-level while `sd.batteryFoo` does not.
                if end < chars.count {
                    let next = chars[end]
                    if next.isLetter || next.isNumber || next == "_" || next == "$" { continue }
                }
                out.insert(permission)
            }
        }
        return out
    }
}
