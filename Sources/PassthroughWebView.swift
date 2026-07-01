import AppKit
import WebKit

/// WKWebView that can opt out of AppKit drag-destination registration.
///
/// WebKit registers every WKWebView for the draggable pasteboard types
/// (WebViewImpl::registerDraggedTypes → the public
/// `registerForDraggedTypes(_:)`), which makes even an
/// `ignoresMouseEvents` panel a drag target: a Finder drag over a
/// click-through stack hits the invisible surface instead of the window
/// beneath. `ignoresMouseEvents` only affects click dispatch — drag
/// sessions route by registered types, so the fix is to keep the
/// registration list empty.
///
/// `dragPassthrough` suppresses registration but REMEMBERS the requested
/// types, so flipping click-through off (the bar's hover-flip,
/// `sd.window.setClickThrough(false)`) restores normal drop behavior.
/// The override also covers WebKit re-registering after navigation or a
/// WebContent process relaunch by construction — every request funnels
/// through it. Invariant after this change: ignoresMouseEvents ⇒ drag-inert.
final class PassthroughWebView: WKWebView {
    var dragPassthrough: Bool { didSet { applyDragPolicy() } }
    /// Last types WebKit (or anyone) asked for while suppressed — replayed
    /// when passthrough is switched off.
    private(set) var deferredDragTypes: [NSPasteboard.PasteboardType] = []

    init(frame: CGRect, configuration: WKWebViewConfiguration, dragPassthrough: Bool) {
        self.dragPassthrough = dragPassthrough
        super.init(frame: frame, configuration: configuration)
        // Two-phase init guarantees the stored properties exist before
        // super.init runs, so the override below is safe even when WebKit
        // registers during its own init; this call covers any registration
        // that bypassed it.
        applyDragPolicy()
    }

    required init?(coder: NSCoder) { fatalError("not NSCoder-instantiated") }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        deferredDragTypes = newTypes
        if dragPassthrough { super.unregisterDraggedTypes() }
        else { super.registerForDraggedTypes(newTypes) }
    }

    private func applyDragPolicy() {
        if dragPassthrough {
            super.unregisterDraggedTypes()
        } else if !deferredDragTypes.isEmpty {
            super.registerForDraggedTypes(deferredDragTypes)
        }
    }
}
