import Carbon.HIToolbox
import Foundation

// MARK: ============================================================
// MARK: Input — keyboard layout (TIS)
// MARK: ============================================================

enum Input {
    static func currentLayout() -> [String: Any] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return ["name": NSNull(), "id": NSNull()]
        }
        let name = cfStringProp(source, kTISPropertyLocalizedName) ?? ""
        let id   = cfStringProp(source, kTISPropertyInputSourceID) ?? ""
        return ["name": name, "id": id]
    }

    /// hs.eventtap.isSecureInputEnabled: true while a password field or
    /// another secure-input client holds the keyboard, when macOS withholds
    /// key events from event taps.
    static func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    private static func cfStringProp(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

final class InputObserver: RefCountedObserver {
    static let shared = InputObserver()
    private override init() { super.init() }

    override func install() -> Token {
        // TIS notifications are CFNotifications via the local distributed center.
        return installNotifications([
            (DistributedNotificationCenter.default(),
             NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))
        ])
    }
}
