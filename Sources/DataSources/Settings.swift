import Foundation

// Per-stack scoped k/v persistence backed by UserDefaults suites.
// Each stack gets its own namespace at `com.stackd.stack.<id>`, isolated
// from every other stack. Stored values are plist-compatible — i.e.
// anything JSON-serializable (String, Number, Bool, Array, Dict, null).
//
// Why a per-stack suite instead of one shared bucket with prefixed keys:
// - cleaner deletion (suite-wide reset)
// - shows up as its own group in `defaults` CLI for debugging
// - no key-collision worries between stacks
final class StackSettings {
    let suite: UserDefaults
    let stackId: String

    init(stackId: String) {
        self.stackId = stackId
        self.suite = UserDefaults(suiteName: "com.stackd.stack.\(stackId)") ?? .standard
    }

    func get(_ key: String) -> Any? {
        return suite.object(forKey: key)
    }

    func set(_ key: String, _ value: Any?) {
        // UserDefaults only stores plist types (String/Number/Bool/Date/Data/
        // Array/Dict). NSNull anywhere in the tree crashes the write. Sanitize
        // recursively — strip NSNull from arrays/dicts, drop top-level NSNull.
        if let v = value, let sanitized = StackSettings.sanitize(v) {
            suite.set(sanitized, forKey: key)
        } else {
            suite.removeObject(forKey: key)
        }
    }

    private static func sanitize(_ v: Any) -> Any? {
        if v is NSNull { return nil }
        if let arr = v as? [Any] {
            return arr.compactMap { sanitize($0) }
        }
        if let dict = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, val) in dict {
                if let san = sanitize(val) { out[k] = san }
            }
            return out
        }
        return v
    }

    func delete(_ key: String) {
        suite.removeObject(forKey: key)
    }

    /// Stack-scoped key set (excludes the global UserDefaults bleed-through).
    /// UserDefaults' dictionaryRepresentation includes everything inherited
    /// from the parents, so we filter to keys actually written to OUR suite.
    func all() -> [String: Any] {
        guard let persistent = suite.persistentDomain(forName: "com.stackd.stack.\(stackId)") else {
            return [:]
        }
        return persistent
    }
}
