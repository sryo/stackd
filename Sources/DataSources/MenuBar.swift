import Foundation

// CGSSetMenuBarVisibility lives in SkyLight private framework. Loaded via
// dlopen so it degrades to a no-op if the symbol is ever moved or removed.
// This is the same "vendor private SPI" pattern as DisplayServicesShim.
enum SkyLight {
    typealias SetMenuBarVisibilityFn = @convention(c) (Bool) -> Void

    static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    static let setMenuBarVisibility: SetMenuBarVisibilityFn? = {
        guard let h = handle, let sym = dlsym(h, "CGSSetMenuBarVisibility") else { return nil }
        return unsafeBitCast(sym, to: SetMenuBarVisibilityFn.self)
    }()
}

/// Reference-counted system menu-bar visibility. Multiple stacks can suppress;
/// the menu bar reappears only when every suppressor has called restore().
enum MenuBarVisibility {
    private static let lock = NSLock()
    private static var suppressorCount = 0

    @discardableResult
    static func suppress() -> Bool {
        guard let fn = SkyLight.setMenuBarVisibility else { return false }
        lock.lock(); defer { lock.unlock() }
        suppressorCount += 1
        if suppressorCount == 1 { fn(false) }
        return true
    }

    @discardableResult
    static func restore() -> Bool {
        guard let fn = SkyLight.setMenuBarVisibility else { return false }
        lock.lock(); defer { lock.unlock() }
        suppressorCount = max(0, suppressorCount - 1)
        if suppressorCount == 0 { fn(true) }
        return true
    }

    /// Called on daemon shutdown / reload so we never leak the menu bar hidden.
    static func resetForReload() {
        guard let fn = SkyLight.setMenuBarVisibility else { return }
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
        let symOK    = SkyLight.setMenuBarVisibility != nil
        FileHandle.standardError.write(Data("stackd: SkyLight handle=\(handleOK) sym=\(symOK)\n".utf8))
        guard let fn = SkyLight.setMenuBarVisibility else { return }
        lock.lock(); defer { lock.unlock() }
        suppressorCount = 0
        fn(true)
    }
}
