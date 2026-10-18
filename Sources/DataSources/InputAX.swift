import AppKit
import ApplicationServices
import Foundation

// MARK: ============================================================
// MARK: InputAX — curated AX reader/setters for the focused text element
// MARK: ============================================================

// Curated AX surface for "whatever has keyboard focus right now." Replaces
// the five-call sd.ax.* dance (focused → attribute → parameterizedAttribute →
// release) muse, palette, and text-expander stacks were doing for every
// transformation tick. System-wide focused element, 100ms messaging timeout
// (matches Apps.menu pattern), all reads/writes hop to main via Bridge's
// `.ax` dispatch — AX traffic deadlocks under cross-thread access.
//
// Coordinate convention: AX returns screen-points (top-left origin), same
// space sd.windows.byId.frame / sd.mouse.location report. No Y-flip.
//
// Known-slow apps (kAXSelectedTextAttribute returns nothing): Safari /
// Mail / Firefox WebViews. The reader still returns `text` + `selectedRange`
// in those cases, just with `selectedText` as the empty string.

enum InputAX {
    /// System-wide focused element snapshot. Returns nil when no AX-text
    /// element has focus (e.g. focus is on a button, or no app is frontmost).
    ///
    /// Shape:
    ///   { text, selectedText, selectedRange: {location, length},
    ///     caretRect: {x, y, w, h} | null,
    ///     role, subrole, value, pid, app }
    static func focusedText() -> [String: Any]? {
        guard let el = focusedElement() else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)

        let role    = stringAttr(el, kAXRoleAttribute) ?? ""
        let subrole = stringAttr(el, kAXSubroleAttribute) ?? ""
        let value   = stringAttr(el, kAXValueAttribute) ?? ""

        // selectedText is the substring the user has highlighted; absent or
        // empty when there's just a caret. WebViews (Safari/Mail/Firefox)
        // commonly leave this unset even when AXValue is populated.
        let selectedText = stringAttr(el, kAXSelectedTextAttribute) ?? ""

        var selectedRange: [String: Int] = ["location": 0, "length": 0]
        var caretRect: Any = NSNull()
        if let range = rangeAttr(el, kAXSelectedTextRangeAttribute) {
            selectedRange = ["location": range.location, "length": range.length]
            if let bounds = boundsForRange(el, range: range) {
                caretRect = [
                    "x": Double(bounds.origin.x),
                    "y": Double(bounds.origin.y),
                    "w": Double(bounds.size.width),
                    "h": Double(bounds.size.height)
                ] as [String: Double]
            }
        }

        // Resolve owning app via NSWorkspace.frontmost rather than walking
        // AXParent — the parent chain can be deep (input field → group → …
        // → AXApplication) and frontmostApplication is exact for "what app
        // owns the focused element" the same way HS's
        // hs.application.frontmostApplication() reports.
        let front = NSWorkspace.shared.frontmostApplication
        let pid: Int = front.map { Int($0.processIdentifier) } ?? 0
        let app: String = front?.localizedName ?? ""

        return [
            "text":          value,
            "selectedText":  selectedText,
            "selectedRange": selectedRange,
            "caretRect":     caretRect,
            "role":          role,
            "subrole":       subrole,
            "value":         value,
            "pid":           pid,
            "app":           app
        ]
    }

    /// Replace the current selection in the focused element with `value`.
    /// If there's no selection (just a caret), `value` is inserted at the
    /// caret. Returns false when there's no focused text element or the
    /// element rejects the write (kAXValueAttribute isn't settable on
    /// readonly fields — `selectedText` write fails silently in WebViews).
    @discardableResult
    static func setSelectedText(_ value: String) -> Bool {
        guard let el = focusedElement() else { return false }
        AXUIElementSetMessagingTimeout(el, 0.1)
        return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, value as CFString) == .success
    }

    /// Move the selection (and caret) in the focused element. `length` 0
    /// places a caret at `location`; positive `length` selects the range.
    /// Returns false when there's no focused element or the field doesn't
    /// support kAXSelectedTextRangeAttribute.
    @discardableResult
    static func setSelectedRange(location: Int, length: Int) -> Bool {
        guard let el = focusedElement() else { return false }
        AXUIElementSetMessagingTimeout(el, 0.1)
        var range = CFRange(location: location, length: length)
        guard let axVal = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axVal) == .success
    }

    // MARK: - Internals

    /// System-wide AXFocusedUIElement (vs AX.focusedElement which goes
    /// frontmost-app → focused). System-wide handles edge cases where
    /// focus lives in a service window or accessibility-inspector style
    /// element that doesn't belong to NSWorkspace.frontmost.
    private static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.1)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let focused = ref else { return nil }
        // swiftlint:disable:next force_cast
        return (focused as! AXUIElement)
    }

    private static func stringAttr(_ el: AXUIElement, _ key: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func rangeAttr(_ el: AXUIElement, _ key: String) -> CFRange? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success,
              let value = ref else { return nil }
        // swiftlint:disable:next force_cast
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
        // swiftlint:disable:next force_cast
        let axVal = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axVal, .cgRect, &rect) else { return nil }
        return rect
    }
}
