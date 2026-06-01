import Foundation

// Pending macOS software updates via `softwareupdate -l`. No TCC required;
// the tool runs without escalation when only LISTING updates (install
// needs sudo, which this primitive doesn't expose).
//
// The subprocess is slow (5-10s — does a network round-trip to Apple's
// update catalog). list() caches the most recent result and returns it
// immediately for the cache TTL window; pass force: true to bust the cache.
// Stacks rendering an "update available" badge poll every few hours; the
// cache makes that cheap.
//
// Parser is pure and unit-tested (Tests/UpdateParserTests.swift). The
// subprocess + cache hop is impure and isn't tested in isolation.

enum Update {
    private static var cache: (updates: [[String: Any]], at: TimeInterval)?
    private static let lock = NSLock()
    private static let defaultTTL: TimeInterval = 6 * 3600  // 6 hours

    /// Pending updates as `[{ label, title?, version?, sizeKiB?, recommended, requiresRestart }, ...]`.
    /// Cached for `ttlSeconds`; pass `force: true` to refresh now. Completion
    /// always fires on the main queue.
    static func list(force: Bool = false,
                     ttlSeconds: TimeInterval? = nil,
                     completion: @escaping ([[String: Any]]) -> Void) {
        let ttl = ttlSeconds ?? defaultTTL
        if !force, let c = cached(within: ttl) {
            DispatchQueue.main.async { completion(c) }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let raw = run("/usr/sbin/softwareupdate", ["-l"]) ?? ""
            let updates = parse(raw)
            store(updates)
            DispatchQueue.main.async { completion(updates) }
        }
    }

    private static func cached(within ttl: TimeInterval) -> [[String: Any]]? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache, Date().timeIntervalSince1970 - c.at < ttl else { return nil }
        return c.updates
    }

    private static func store(_ updates: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        cache = (updates, Date().timeIntervalSince1970)
    }

    /// Parse `softwareupdate -l` stdout into per-update dicts. Public for
    /// testability — see Tests/UpdateParserTests.swift.
    ///
    /// Expected shape per update:
    ///   * Label: <label>
    ///     \tTitle: <title>, Version: <ver>, Size: <n>KiB, Recommended: YES|NO, Action: restart,
    /// The details line is optional — a bare `* Label:` entry still becomes
    /// an entry (label-only). Action: restart is the only signal Apple emits
    /// for "this needs a reboot."
    static func parse(_ stdout: String) -> [[String: Any]] {
        var updates: [[String: Any]] = []
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let label = matchLabel(line) {
                var entry: [String: Any] = ["label": label, "recommended": false, "requiresRestart": false]
                if i + 1 < lines.count {
                    let next = lines[i + 1]
                    if mergeDetails(into: &entry, from: String(next)) {
                        i += 2
                        updates.append(entry)
                        continue
                    }
                }
                updates.append(entry)
            }
            i += 1
        }
        return updates
    }

    /// `* Label: <name>` → `<name>`; trims leading "* Label:" + whitespace.
    /// Returns nil if the line doesn't match the label preamble.
    private static func matchLabel(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "* Label:"
        guard trimmed.hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Parse the comma-separated details line (Title/Version/Size/Recommended/Action)
    /// into the entry dict. Returns true if the line was a details line (so
    /// the caller skips it on the next iteration), false otherwise.
    private static func mergeDetails(into entry: inout [String: Any], from line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A details line always starts with "Title:" — anything else means
        // the next entry, blank line, or trailing noise.
        guard trimmed.hasPrefix("Title:") else { return false }
        // Split on ", " — Apple's format is stable here. Empty trailing
        // fields (from the trailing comma) get dropped by the trim filter.
        for part in trimmed.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key   = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            switch key {
            case "Title":       entry["title"]   = value
            case "Version":     entry["version"] = value
            case "Size":
                // "7159564KiB" → 7159564
                if value.hasSuffix("KiB"),
                   let n = Int(value.dropLast("KiB".count)) {
                    entry["sizeKiB"] = n
                }
            case "Recommended": entry["recommended"]     = (value == "YES")
            case "Action":      entry["requiresRestart"] = (value == "restart")
            default:            break
            }
        }
        return true
    }

    /// Synchronously run a tool and return stdout as a String, or nil on
    /// launch failure / nonzero exit.
    private static func run(_ tool: String, _ args: [String]) -> String? {
        let task = Process()
        task.launchPath = tool
        task.arguments = args
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError  = err
        do { try task.run() } catch { return nil }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        _ = try? err.fileHandleForReading.readToEnd()
        task.waitUntilExit()
        // softwareupdate -l prints to stderr in some versions, stdout in
        // others. We capture stdout; on empty output the caller treats it
        // as "no updates available" which is the safe default.
        return String(data: data, encoding: .utf8)
    }
}
