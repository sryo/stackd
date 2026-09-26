import Foundation

/// Reference-counted desktop-icon hiding (sd.desktop.hideIcons / showIcons).
///
/// Finder draws the icons in its own window, and WindowServer ignores alpha
/// changes on windows another connection owns, so there is no SkyLight route.
/// Instead this flips the "Show Items: On Desktop" setting, stored as
/// `StandardHideDesktopIcons` in com.apple.WindowManager. WindowManager
/// observes that key through KVO on UserDefaults, which also fires for writes
/// from other processes, so the change applies without relaunching Finder.
///
/// The preference persists, unlike the menu-bar override, so a crashed daemon
/// would leave the icons hidden. Before hiding, the user's prior value goes
/// into a marker file; `recoverOnLaunch` puts it back if the marker survives.
final class DesktopIcons {
    struct Marker: Codable, Equatable {
        /// nil when the key was unset (the system default: icons shown).
        let prior: Bool?
    }

    static let shared = DesktopIcons(
        readHidden: {
            CFPreferencesCopyAppValue(prefKey, prefDomain) as? Bool
        },
        writeHidden: { value in
            CFPreferencesSetAppValue(prefKey, value.map { $0 as CFBoolean }, prefDomain)
            CFPreferencesAppSynchronize(prefDomain)
        },
        loadMarker: {
            guard let data = FileManager.default.contents(atPath: markerPath) else { return nil }
            return try? JSONDecoder().decode(Marker.self, from: data)
        },
        saveMarker: { marker in
            if let marker, let data = try? JSONEncoder().encode(marker) {
                try? FileManager.default.createDirectory(atPath: IPC.socketDir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: markerPath, contents: data)
            } else {
                try? FileManager.default.removeItem(atPath: markerPath)
            }
        })

    private static let prefDomain = "com.apple.WindowManager" as CFString
    private static let prefKey = "StandardHideDesktopIcons" as CFString
    private static var markerPath: String { IPC.socketDir + "/desktop-icons-hidden.json" }

    private let readHidden: () -> Bool?
    private let writeHidden: (Bool?) -> Void
    private let loadMarker: () -> Marker?
    private let saveMarker: (Marker?) -> Void
    private let lock = NSLock()
    private var holders = 0
    private var prior: Bool?

    init(readHidden: @escaping () -> Bool?,
         writeHidden: @escaping (Bool?) -> Void,
         loadMarker: @escaping () -> Marker?,
         saveMarker: @escaping (Marker?) -> Void) {
        self.readHidden = readHidden
        self.writeHidden = writeHidden
        self.loadMarker = loadMarker
        self.saveMarker = saveMarker
    }

    /// Hides the icons until the returned Token (and every other holder's)
    /// is cancelled. Cancelling twice releases once.
    func hide() -> Token {
        lock.lock()
        holders += 1
        if holders == 1 {
            prior = readHidden()
            saveMarker(Marker(prior: prior))
            writeHidden(true)
        }
        lock.unlock()
        var released = false
        return Token { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard !released, self.holders > 0 else { return }
            released = true
            self.holders -= 1
            if self.holders == 0 { self.restore(to: self.prior) }
        }
    }

    /// Daemon shutdown: show the icons again whatever the holders say.
    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        guard holders > 0 else { return }
        holders = 0
        restore(to: prior)
    }

    /// Daemon launch: undo a hide a previous daemon never released.
    func recoverOnLaunch() {
        lock.lock(); defer { lock.unlock() }
        guard let marker = loadMarker() else { return }
        restore(to: marker.prior)
    }

    /// Caller holds `lock`. Writes only when the preference still holds our
    /// `true`, so a change the user made in System Settings meanwhile wins.
    private func restore(to value: Bool?) {
        if readHidden() == true { writeHidden(value) }
        saveMarker(nil)
    }
}
