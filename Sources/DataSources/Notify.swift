import Foundation

// Native banner notifications. Fire-and-forget.
//
// Why osascript instead of UNUserNotificationCenter: UNUserNotificationCenter
// needs stackd to request notification authorization, which puts a system
// prompt in front of the user. `osascript -e 'display notification "..."'`
// routes through Script Editor's notification permission, which is granted by
// default in fresh user accounts. Trade-off: notifications show up attributed
// to "Script Editor" rather than "stackd", and we can't programmatically
// observe taps.

enum Notify {
    /// Spawns the osascript subprocess without waiting for it. Returns
    /// whether it launched. Quoting handles `"` and `\` in title/body —
    /// anything else is passed through. AppleScript display notification
    /// supports: title, subtitle, body, sound name.
    @discardableResult
    static func show(title: String, body: String, subtitle: String? = nil, sound: String? = nil) -> Bool {
        // Best-effort: if osascript isn't reachable or the notification daemon
        // rejects, we silently no-op rather than crash the daemon.
        Proc.exec(cmd: "/usr/bin/osascript",
                  args: ["-e", script(title: title, body: body, subtitle: subtitle, sound: sound)]) { _ in }
    }

    /// The AppleScript line. Order: body text, then `with title ...`, then
    /// optional `subtitle ...`, then optional `sound name ...`.
    internal static func script(title: String, body: String, subtitle: String?, sound: String?) -> String {
        var script = "display notification \(escape(body))"
        script += " with title \(escape(title))"
        if let sub = subtitle { script += " subtitle \(escape(sub))" }
        if let snd = sound    { script += " sound name \(escape(snd))" }
        return script
    }

    /// AppleScript string literal: wrap in double quotes, escape backslashes
    /// then double quotes. Keeps the rest of the body intact. Order matters —
    /// backslashes MUST be escaped before quotes, otherwise the `\"` we
    /// produce for a quote would itself get re-escaped to `\\"` and break
    /// the AppleScript parser.
    internal static func escape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
