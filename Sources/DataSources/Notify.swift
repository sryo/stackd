import Foundation

// Native banner notifications. Fire-and-forget.
//
// Why osascript instead of UNUserNotificationCenter: stackd ships today
// as a raw CLI binary (build.sh produces .build/stackd, no .app bundle).
// UNUserNotificationCenter.requestAuthorization wants a CFBundleIdentifier
// from a real Info.plist — without it the system silently drops notifications.
// `osascript -e 'display notification "..."'` routes through Script Editor's
// notification permission, which is granted by default in fresh user accounts.
// Trade-off: notifications show up attributed to "Script Editor" rather than
// "stackd", and we can't programmatically observe taps. v2 swaps in
// UNUserNotificationCenter once stackd ships as a bundled .app.
//
// Two consumers queued from the audit: apptimeout (warn at 4-minute mark),
// notunes (toast on Music kill). bar/battery-low becomes consumer 3.

enum Notify {
    /// Spawns the osascript subprocess. Quoting handles `"` and `\` in
    /// title/body — anything else is passed through. AppleScript display
    /// notification supports: title, subtitle, body, sound name.
    @discardableResult
    static func show(title: String, body: String, subtitle: String? = nil, sound: String? = nil) -> Bool {
        // Build the AppleScript line. Order: body text, then `with title ...`,
        // then optional `subtitle ...`, then optional `sound name ...`.
        var script = "display notification \(escape(body))"
        script += " with title \(escape(title))"
        if let sub = subtitle { script += " subtitle \(escape(sub))" }
        if let snd = sound    { script += " sound name \(escape(snd))" }

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        // Best-effort: if osascript isn't reachable or the notification daemon
        // rejects, we silently no-op rather than crash the daemon. The caller
        // gets back true only when launch succeeded.
        do {
            try task.run()
            return true
        } catch {
            return false
        }
    }

    /// AppleScript string literal: wrap in double quotes, escape backslashes
    /// then double quotes. Keeps the rest of the body intact.
    private static func escape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
