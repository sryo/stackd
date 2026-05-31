import Foundation
import OSAKit

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
    ///   ["ok": Bool, "result": String, "error": String?]
    /// `result` is the AppleScript value coerced to string ("" if void).
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
        let str = desc?.stringValue ?? ""
        return ["ok": true, "result": str]
    }
}
