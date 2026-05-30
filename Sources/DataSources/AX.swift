import AppKit
import ApplicationServices

// Generic AX primitive — opaque-handle API modeled on Hammerspoon's
// hs.axuielement. The Bridge owns the handle store (one per stack) and
// hands AXUIElementRefs out as integer handles to JS. AX traffic must
// stay on main: the AXUIElement APIs claim thread safety but real apps
// deadlock under cross-thread traffic.
//
// focusedElement() — back-compat helper, used by Palette MVP for the
// caret-aware overlay path. Everything else flows through the handle API.

enum AX {
    // MARK: - Back-compat: focused element dict

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

    // MARK: - Handle store

    /// Per-Bridge store of live AXUIElementRefs keyed by integer handle.
    /// The Bridge owns one of these and passes it in to every call. Handles
    /// are opaque to JS; stacks must release(h) or releaseAll() to free them.
    final class HandleStore {
        private var map: [Int: AXUIElement] = [:]
        private var next: Int = 1

        func mint(_ el: AXUIElement) -> Int {
            let h = next
            next += 1
            map[h] = el
            return h
        }

        func get(_ h: Int) -> AXUIElement? { map[h] }

        @discardableResult
        func release(_ h: Int) -> Bool { map.removeValue(forKey: h) != nil }

        func releaseAll() { map.removeAll() }
    }

    // MARK: - Element creation

    static func application(pid: pid_t, store: HandleStore) -> Int {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.5)
        return store.mint(el)
    }

    static func systemWide(store: HandleStore) -> Int {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.5)
        return store.mint(el)
    }

    static func systemElementAtPosition(x: Float, y: Float, store: HandleStore) -> Int? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.5)
        var ref: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(sys, x, y, &ref)
        guard err == .success, let el = ref else { return nil }
        return store.mint(el)
    }

    static func focusedElementHandle(store: HandleStore) -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &ref)
        guard err == .success, let focused = ref else { return nil }
        return store.mint(focused as! AXUIElement)
    }

    // MARK: - Introspection

    static func attributeNames(handle: Int, store: HandleStore) -> [String]? {
        guard let el = store.get(handle) else { return nil }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success, let arr = names else { return nil }
        return (arr as? [String]) ?? []
    }

    static func parameterizedAttributeNames(handle: Int, store: HandleStore) -> [String]? {
        guard let el = store.get(handle) else { return nil }
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(el, &names) == .success, let arr = names else { return nil }
        return (arr as? [String]) ?? []
    }

    static func actionNames(handle: Int, store: HandleStore) -> [String]? {
        guard let el = store.get(handle) else { return nil }
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let arr = names else { return nil }
        return (arr as? [String]) ?? []
    }

    static func attribute(handle: Int, name: String, store: HandleStore) -> Any? {
        guard let el = store.get(handle) else { return nil }
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success, let v = ref else { return nil }
        return marshal(v, store: store)
    }

    static func attributes(handle: Int, store: HandleStore) -> [String: Any]? {
        guard let el = store.get(handle) else { return nil }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success, let arr = names,
              let nameList = arr as? [String] else { return nil }
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, nameList as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let raw = values as? [AnyObject] else { return nil }
        var out: [String: Any] = [:]
        for (i, name) in nameList.enumerated() where i < raw.count {
            let item = raw[i] as CFTypeRef
            // Skip slots that came back as an embedded AXError sentinel.
            if CFGetTypeID(item) == AXValueGetTypeID(),
               AXValueGetType(item as! AXValue) == .axError {
                continue
            }
            out[name] = marshal(raw[i], store: store)
        }
        return out
    }

    static func parameterizedAttribute(handle: Int, name: String, param: Any?, store: HandleStore) -> Any? {
        guard let el = store.get(handle) else { return nil }
        guard let cfParam = toCFType(param, store: store) else { return nil }
        var ref: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(el, name as CFString, cfParam, &ref)
        guard err == .success, let v = ref else { return nil }
        return marshal(v, store: store)
    }

    static func isAttributeSettable(handle: Int, name: String, store: HandleStore) -> Bool? {
        guard let el = store.get(handle) else { return nil }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success else { return nil }
        return settable.boolValue
    }

    // MARK: - Mutation

    @discardableResult
    static func setAttribute(handle: Int, name: String, value: Any?, store: HandleStore) -> Bool {
        guard let el = store.get(handle) else { return false }
        guard let cfVal = toCFType(value, store: store) else { return false }
        return AXUIElementSetAttributeValue(el, name as CFString, cfVal) == .success
    }

    @discardableResult
    static func performAction(handle: Int, action: String, store: HandleStore) -> Bool {
        guard let el = store.get(handle) else { return false }
        return AXUIElementPerformAction(el, action as CFString) == .success
    }

    // MARK: - Convenience walks

    static func children(handle: Int, store: HandleStore) -> [Int]? {
        guard let el = store.get(handle) else { return nil }
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return nil }
        return arr.map { store.mint($0) }
    }

    static func parent(handle: Int, store: HandleStore) -> Int? {
        guard let el = store.get(handle) else { return nil }
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &ref) == .success,
              let parent = ref else { return nil }
        return store.mint(parent as! AXUIElement)
    }

    static func role(handle: Int, store: HandleStore) -> String? {
        guard let el = store.get(handle) else { return nil }
        return stringAttr(el, kAXRoleAttribute)
    }

    // MARK: - Marshalling (CFType → JSON-able Any)

    /// Mirrors hs.axuielement's pushCFTypeToLua. AXUIElementRefs get minted
    /// as fresh handles every read — stacks must release explicitly.
    private static func marshal(_ value: AnyObject, store: HandleStore) -> Any {
        let cf = value as CFTypeRef
        let tid = CFGetTypeID(cf)

        if tid == AXUIElementGetTypeID() {
            return store.mint(cf as! AXUIElement)
        }
        if tid == AXValueGetTypeID() {
            let v = cf as! AXValue
            switch AXValueGetType(v) {
            case .cgPoint:
                var p = CGPoint.zero
                if AXValueGetValue(v, .cgPoint, &p) {
                    return ["x": Double(p.x), "y": Double(p.y)]
                }
            case .cgSize:
                var s = CGSize.zero
                if AXValueGetValue(v, .cgSize, &s) {
                    return ["w": Double(s.width), "h": Double(s.height)]
                }
            case .cgRect:
                var r = CGRect.zero
                if AXValueGetValue(v, .cgRect, &r) {
                    return [
                        "x": Double(r.origin.x), "y": Double(r.origin.y),
                        "w": Double(r.size.width), "h": Double(r.size.height)
                    ]
                }
            case .cfRange:
                var rg = CFRange(location: 0, length: 0)
                if AXValueGetValue(v, .cfRange, &rg) {
                    return ["location": rg.location, "length": rg.length]
                }
            case .axError, .illegal:
                return NSNull()
            @unknown default:
                return NSNull()
            }
            return NSNull()
        }
        if tid == CFArrayGetTypeID() {
            let arr = cf as! NSArray
            return arr.map { marshal($0 as AnyObject, store: store) }
        }
        if tid == CFDictionaryGetTypeID() {
            let dict = cf as! NSDictionary
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if let key = k as? String {
                    out[key] = marshal(v as AnyObject, store: store)
                }
            }
            return out
        }
        if tid == CFBooleanGetTypeID() {
            return (cf as! NSNumber).boolValue
        }
        if tid == CFNumberGetTypeID() {
            return cf as! NSNumber
        }
        if tid == CFStringGetTypeID() {
            return cf as! String
        }
        if tid == CFURLGetTypeID() {
            return (cf as! NSURL).absoluteString ?? ""
        }
        if tid == CFAttributedStringGetTypeID() {
            return (cf as! NSAttributedString).string
        }
        // AXTextMarker / AXTextMarkerRange / unknowns: drop. JS stacks needing
        // those should add a dedicated primitive (HS has axtextmarker.m).
        return NSNull()
    }

    /// JS value → CFType for setAttribute / parameterized reads.
    /// Numbers that match a known handle aren't auto-wrapped — pass the
    /// AXUIElement explicitly via a dict {"_handle": h} if needed.
    private static func toCFType(_ value: Any?, store: HandleStore) -> CFTypeRef? {
        guard let value = value else { return kCFNull }
        if let s = value as? String { return s as CFString }
        if let b = value as? Bool { return (b ? kCFBooleanTrue : kCFBooleanFalse) }
        if let n = value as? NSNumber { return n as CFNumber }
        if let dict = value as? [String: Any] {
            if let h = dict["_handle"] as? Int, let el = store.get(h) {
                return el
            }
            // Shape sniff: AX expects AXValueRef for CGPoint/CGSize/CGRect/CFRange.
            let hasX = dict["x"] != nil, hasY = dict["y"] != nil
            let hasW = dict["w"] != nil, hasH = dict["h"] != nil
            let hasLoc = dict["location"] != nil, hasLen = dict["length"] != nil
            if hasX && hasY && hasW && hasH {
                var r = CGRect(x: (dict["x"] as? Double) ?? 0,
                               y: (dict["y"] as? Double) ?? 0,
                               width: (dict["w"] as? Double) ?? 0,
                               height: (dict["h"] as? Double) ?? 0)
                return AXValueCreate(.cgRect, &r)
            }
            if hasX && hasY {
                var p = CGPoint(x: (dict["x"] as? Double) ?? 0,
                                y: (dict["y"] as? Double) ?? 0)
                return AXValueCreate(.cgPoint, &p)
            }
            if hasW && hasH {
                var s = CGSize(width: (dict["w"] as? Double) ?? 0,
                               height: (dict["h"] as? Double) ?? 0)
                return AXValueCreate(.cgSize, &s)
            }
            if hasLoc && hasLen {
                var rg = CFRange(location: (dict["location"] as? Int) ?? 0,
                                 length: (dict["length"] as? Int) ?? 0)
                return AXValueCreate(.cfRange, &rg)
            }
            return dict as CFDictionary
        }
        if let arr = value as? [Any] { return arr as CFArray }
        return nil
    }

    // MARK: - Focused-element AX helpers (used by focusedElement() above)

    private static func stringAttr(_ el: AXUIElement, _ key: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func rangeAttr(_ el: AXUIElement, _ key: String) -> CFRange? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success,
              let value = ref else { return nil }
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
