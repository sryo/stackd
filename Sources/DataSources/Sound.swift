import AppKit

// Fire-and-forget audio playback via NSSound. No completion callback, no
// playback tracking — Hammerspoon's hs.sound is the reference shape.
//
// Lifecycle: NSSound retains itself while playing, so we don't need to hold
// a reference. The instance releases once playback ends naturally.

enum Sound {
    /// NSSound(named:) searches /System/Library/Sounds and ~/Library/Sounds
    /// for `<name>.aiff` (and a handful of other extensions).
    @discardableResult
    static func system(_ name: String) -> Bool {
        guard let s = NSSound(named: name) else { return false }
        return s.play()
    }

    /// byReference: true avoids loading the entire file into memory — fine for
    /// short alerts, and the file path persists for the lifetime of playback.
    @discardableResult
    static func file(_ path: String) -> Bool {
        let p = (path as NSString).expandingTildeInPath
        guard let s = NSSound(contentsOfFile: p, byReference: true) else { return false }
        return s.play()
    }

    static func beep() {
        NSSound.beep()
    }
}
