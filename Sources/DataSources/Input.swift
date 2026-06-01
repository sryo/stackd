import AppKit
import Carbon

enum Input {
    static func currentLayout() -> [String: Any] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return ["name": NSNull(), "id": NSNull()]
        }
        let name = cfStringProp(source, kTISPropertyLocalizedName) ?? ""
        let id   = cfStringProp(source, kTISPropertyInputSourceID) ?? ""
        return ["name": name, "id": id]
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
