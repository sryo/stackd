import Foundation

// Imperative read of CFPreferences (the `defaults` command's backend).
// Exposed to JS as `sd.defaults.read(bundleId, key) → Promise<value>` — the
// first request/response shape in stackd (everything else is a signal push).
enum Defaults {
    static func read(bundleId: String, key: String) -> Any? {
        guard let raw = CFPreferencesCopyAppValue(key as CFString, bundleId as CFString) else {
            return nil
        }
        return coerce(raw)
    }

    private static func coerce(_ v: CFTypeRef) -> Any {
        if let s = v as? String  { return s }
        if let b = v as? Bool    { return b }
        if let n = v as? NSNumber { return n }
        if let a = v as? [Any]   { return a.map { coerce($0 as CFTypeRef) } }
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, val) in d { out[k] = coerce(val as CFTypeRef) }
            return out
        }
        return String(describing: v)
    }
}
