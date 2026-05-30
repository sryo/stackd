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
final class PasteboardObserver {
    static let shared = PasteboardObserver()
    private var subs: [() -> Void] = []
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?

    private init() {
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let cc = NSPasteboard.general.changeCount
            if cc != self.lastChangeCount {
                self.lastChangeCount = cc
                for cb in self.subs { cb() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func subscribe(_ cb: @escaping () -> Void) { subs.append(cb) }
    func unsubscribeAll() { subs.removeAll() }
}
