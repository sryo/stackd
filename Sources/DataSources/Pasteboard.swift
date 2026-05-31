import AppKit

enum Pasteboard {
    static func getString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    @discardableResult
    static func setString(_ s: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(s, forType: .string)
    }

    static var changeCount: Int { NSPasteboard.general.changeCount }
}

/// 200ms poll for NSPasteboard.changeCount. AppKit has no notification
/// for pasteboard changes; this is the standard Cocoa pattern.
final class PasteboardObserver: RefCountedObserver {
    static let shared = PasteboardObserver()
    private override init() { super.init() }

    override func install() -> Token {
        // AppKit has no pasteboard-change notification; standard pattern is to
        // poll changeCount. While *no* stack subscribes, the timer is gone and
        // we don't pay this 5 Hz cost at all.
        var lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            let cc = NSPasteboard.general.changeCount
            if cc != lastChangeCount {
                lastChangeCount = cc
                self?.fire()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        return Token { t.invalidate() }
    }
}
