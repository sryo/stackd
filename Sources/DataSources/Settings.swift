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
        if let v = value, !(v is NSNull) {
            suite.set(v, forKey: key)
        } else {
            suite.removeObject(forKey: key)
        }
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
