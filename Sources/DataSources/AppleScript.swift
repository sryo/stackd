import Foundation
import OSAKit
import Carbon

// In-process AppleScript / JXA runner. OSAKit picks the language at runtime
// (NSAppleScript is AppleScript-only, OSAScript handles both). Faster than
// spawning /usr/bin/osascript per call since the script compiles + executes
// in the daemon's address space — relevant for "every keystroke" callers.
//
// Limitation: executeAndReturnError is synchronous with no built-in timeout.
// v1 runs to completion; a misbehaving script that hangs for >timeout
// blocks the dispatch hop it's scheduled on (the Bridge schedules onto main).
// Subprocess fallback for hard-timeouts is a future addition — until then,
// callers that need a guaranteed bound on wall-time should keep using
// sd.proc.exec("/usr/bin/osascript", ...).

enum AppleScript {
    /// Run an AppleScript or JXA source string. Returns:
    ///   ["ok": Bool, "result": Any, "error": String?]
    /// `result` preserves the script's return type — numbers stay numbers,
    /// lists become arrays, records become objects, strings stay strings,
    /// booleans stay booleans. Matches `hs.osascript` shape (see
    /// hammerspoon/extensions/osascript/NSAppleEventDescriptor+Parsing.m).
    /// Void returns coerce to "" so existing callers see a stable shape.
    /// `language` is "applescript" (default) or "javascript".
    static func run(source: String, language: String = "applescript",
                    timeoutSeconds: Double = 10) -> [String: Any] {
        let langName = (language == "javascript") ? "JavaScript" : "AppleScript"
        guard let lang = OSALanguage(forName: langName) else {
            return ["ok": false, "result": "", "error": "language not available: \(langName)"]
        }
        let script = OSAScript(source: source, language: lang)
        var error: NSDictionary?
        let desc = script.executeAndReturnError(&error)
        if let error = error {
            let msg = (error[OSAScriptErrorMessageKey] as? String)
                ?? (error[NSAppleScript.errorMessage] as? String)
                ?? "unknown error"
            return ["ok": false, "result": "", "error": msg]
        }
        let value: Any = desc.map { descriptorToJSON($0) } ?? ""
        return ["ok": true, "result": value]
    }

    /// Walk an NSAppleEventDescriptor and produce a JSON-encodable value.
    /// Mirrors hs.osascript's `NSAppleEventDescriptor (GenericObject) objectValue`
    /// category, but in Swift with explicit DescType cases. Anything we don't
    /// recognize falls back to `stringValue` (matches the HS default branch).
    private static func descriptorToJSON(_ d: NSAppleEventDescriptor) -> Any {
        switch d.descriptorType {
        case typeTrue:
            return true
        case typeFalse:
            return false
        case typeBoolean:
            return d.booleanValue
        case typeSInt16, typeUInt16, typeSInt32, typeUInt32, typeSInt64, typeUInt64:
            return Int(d.int32Value)
        case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint, type128BitFloatingPoint:
            return d.doubleValue
        case typeUnicodeText, typeUTF8Text, typeText, typeFileURL:
            return d.stringValue ?? ""
        case typeAEList:
            let n = d.numberOfItems
            guard n > 0 else { return [Any]() }
            var arr: [Any] = []
            arr.reserveCapacity(Int(n))
            for i in 1...n {  // AE descriptors are 1-indexed
                if let item = d.atIndex(i) { arr.append(descriptorToJSON(item)) }
            }
            return arr
        case typeAERecord:
            // Records carry their fields under keyASUserRecordFields: an AEList
            // of alternating key/value descriptors. This is the shape HS reads
            // (NSAppleEventDescriptor+Parsing.m :: scriptingUserDefinedRecordWithDescriptor).
            // The older Apple-defined record fields (typeProperty) aren't
            // covered here — that path is rarely hit from script return values
            // and the fall-through `stringValue` keeps it lossy-but-non-fatal.
            var dict: [String: Any] = [:]
            if let userFields = d.forKeyword(AEKeyword(keyASUserRecordFields)) {
                let count = userFields.numberOfItems
                if count >= 2 {
                    var i: Int = 1
                    while i <= count - 1 {
                        if let keyDesc = userFields.atIndex(i),
                           let valDesc = userFields.atIndex(i + 1),
                           let key = keyDesc.stringValue {
                            dict[key] = descriptorToJSON(valDesc)
                        }
                        i += 2
                    }
                }
            }
            return dict
        case typeNull:
            return NSNull()
        default:
            // Includes typeType, typeEnumerated, typeObjectSpecifier, typeAlias,
            // and anything else AppleScript may hand back. stringValue is the
            // same fallback HS uses; nil → "" to keep the value JSON-encodable.
            return d.stringValue ?? ""
        }
    }
}
