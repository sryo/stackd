import AppKit

// Refcounted suppress/restore of the whole macOS menu bar via
// CGSSetMenuBarVisibility (SkyLight private SPI). Backs the
// sd.menubar.suppress / sd.menubar.restore surface.
//
// The NSStatusItem half of sd.menubar.* lives in Menubar.swift — these two
// subsystems just happen to share the word "menubar" but have different APIs,
// different SPIs, and different consumers.

// MARK: - SkyLight CGSSetMenuBarVisibility (shared loader in Sources/Private/SkyLight.swift)

private enum SkyLightMenuBar {
    typealias SetMenuBarVisibilityFn = @convention(c) (Bool) -> Void
    static let setMenuBarVisibility: SetMenuBarVisibilityFn? = SkyLight.sym("CGSSetMenuBarVisibility")
}

// MARK: - Refcounted system menu bar visibility

/// Reference-counted system menu-bar visibility. Multiple stacks can suppress;
/// the menu bar reappears only when every suppressor has called restore().
enum MenuBarVisibility {
    private static let lock = NSLock()
    private static var suppressorCount = 0

    /// Each suppress() returns a Token whose cancel decrements the refcount.
    /// Stacks adopt the Token into their scope so unload always pairs with
    /// suppression — no more leaks if a stack dies between suppress/restore.
    /// Returns nil if SkyLight failed to load.
    static func suppress() -> Token? {
        guard let fn = SkyLightMenuBar.setMenuBarVisibility else { return nil }
        lock.lock()
        suppressorCount += 1
        if suppressorCount == 1 { fn(false) }
        lock.unlock()
        var released = false
        return Token {
            lock.lock(); defer { lock.unlock() }
            // Guard against double-cancel (adopt + explicit cancel).
            guard !released else { return }
            released = true
            suppressorCount = max(0, suppressorCount - 1)
            if suppressorCount == 0 { fn(true) }
        }
    }

    /// Called on daemon shutdown / reload so we never leak the menu bar hidden.
    static func resetForReload() {
        guard let fn = SkyLightMenuBar.setMenuBarVisibility else { return }
        lock.lock(); defer { lock.unlock() }
        if suppressorCount > 0 {
            suppressorCount = 0
            fn(true)
        }
    }

    /// Called once at daemon startup. If a previous daemon died with the menu
    /// bar suppressed (kill -9, crash, power loss), inherit a known-good state
    /// rather than the user's stale "menubar hidden" surprise.
    static func forceRestoreOnLaunch() {
        let handleOK = SkyLight.handle != nil
        let symOK    = SkyLightMenuBar.setMenuBarVisibility != nil
        FileHandle.standardError.write(Data("stackd: SkyLight handle=\(handleOK) sym=\(symOK)\n".utf8))
        guard let fn = SkyLightMenuBar.setMenuBarVisibility else { return }
        lock.lock(); defer { lock.unlock() }
        suppressorCount = 0
        fn(true)
    }
}
