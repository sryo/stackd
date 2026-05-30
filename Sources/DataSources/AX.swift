import AppKit
import ApplicationServices

// Caret-aware read of the focused UI element. Extends what Windows.focused()
// already exposes (window-level info) down to the element-level: which text
// field has focus, where the cursor is on screen, what's selected.
//
// Two consumers (from the port plan): Muse anchors its inline overlay to
// the caret bounds, Palette uses selected text as default input. Both need
// the same primitive — that's why it earns its place.

enum AX {
    static func focusedElement() -> [String: Any]? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.1)

        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &ref)
        guard err == .success, let focused = ref else { return nil }
        let el = focused as! AXUIElement

        var out: [String: Any] = [
            "app":  app.localizedName ?? "",
            "pid":  Int(app.processIdentifier),
            "role": stringAttr(el, kAXRoleAttribute) ?? ""
        ]
        if let role = stringAttr(el, kAXRoleDescriptionAttribute) {
            out["roleDescription"] = role
        }
        if let value = stringAttr(el, kAXValueAttribute) {
            out["value"] = value
        }
        if let selectedText = stringAttr(el, kAXSelectedTextAttribute) {
            out["selectedText"] = selectedText
        }
        if let range = rangeAttr(el, kAXSelectedTextRangeAttribute) {
            out["selectedRange"] = ["location": range.location, "length": range.length]
            // Ask the element to convert that range to screen bounds.
            // Works in any AX-compliant text field (most native macOS apps).
            if let bounds = boundsForRange(el, range: range) {
                out["caretBounds"] = [
                    "x": Int(bounds.origin.x),
                    "y": Int(bounds.origin.y),
                    "w": Int(bounds.size.width),
                    "h": Int(bounds.size.height)
                ]
            }
        }
        return out
    }

    // MARK: - AX helpers

    private static func stringAttr(_ el: AXUIElement, _ key: String) -> String? {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, key as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }

    private static func rangeAttr(_ el: AXUIElement, _ key: String) -> CFRange? {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, key as CFString, &ref)
        guard err == .success, let value = ref else { return nil }
        let axVal = value as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }
        return range
    }

    private static func boundsForRange(_ el: AXUIElement, range: CFRange) -> CGRect? {
        var inputRange = range
        guard let inputVal = AXValueCreate(.cfRange, &inputRange) else { return nil }
        var ref: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, inputVal, &ref)
        guard err == .success, let value = ref else { return nil }
        let axVal = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axVal, .cgRect, &rect) else { return nil }
        return rect
    }
}
