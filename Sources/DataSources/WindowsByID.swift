import AppKit
import ApplicationServices
import CoreGraphics

// Per-window actions targeting a specific CGWindowID. Uses the private SPI
// `_AXUIElementGetWindow` (libACE.dylib via the ApplicationServices framework)
// to map an AXUIElement back to its CGWindowID, then walks each pid's window
// list to build an ID→AXUIElement map. Cached per-pid so consecutive lookups
// for the same app skip the AX traversal.
enum AXShim {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let getWindow: GetWindowFn? = {
        // _AXUIElementGetWindow is exported by ApplicationServices itself;
        // dlsym(RTLD_DEFAULT, ...) finds it without needing a framework path.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            FileHandle.standardError.write(Data("stackd: _AXUIElementGetWindow unavailable\n".utf8))
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()
}

enum WindowsByID {
    // pid → (CGWindowID → AXUIElement). Repopulated lazily on lookup miss.
    private static var axCache: [pid_t: [CGWindowID: AXUIElement]] = [:]
    private static let cacheLock = NSLock()

    // Invalidate all cached AX handles for a pid. Called from the lifecycle
    // observer when a window of that pid is destroyed (we don't know which one
    // without doing the lookup, so drop the whole pid's cache).
    static func invalidateCache(pid: pid_t) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        axCache[pid] = nil
    }

    static func invalidateAll() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        axCache.removeAll()
    }

    /// Resolves a CGWindowID → AXUIElement by walking the app's window list.
    /// Uses a per-pid cache to amortize the AX traversal across calls.
    static func elementFor(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        guard let getWindow = AXShim.getWindow else { return nil }

        cacheLock.lock()
        if let cached = axCache[pid]?[windowID] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return nil }

        var map: [CGWindowID: AXUIElement] = [:]
        for el in arr {
            var wid: CGWindowID = 0
            if getWindow(el, &wid) == .success {
                map[wid] = el
            }
        }

        cacheLock.lock()
        axCache[pid] = map
        cacheLock.unlock()
        return map[windowID]
    }

    // Look up by CGWindowID alone — we walk the CGWindowList to recover the
    // pid (cheap), then dispatch via elementFor(windowID:pid:).
    static func elementFor(windowID: CGWindowID) -> AXUIElement? {
        let target = Int(windowID)
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else { return nil }
        let list = raw as! [[String: Any]]
        for info in list {
            if let n = info[kCGWindowNumber as String] as? Int, n == target,
               let p = info[kCGWindowOwnerPID as String] as? Int {
                return elementFor(windowID: CGWindowID(target), pid: pid_t(p))
            }
        }
        return nil
    }

    @discardableResult
    static func setFrame(windowID: CGWindowID, x: Double, y: Double, w: Double, h: Double) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        var pos = CGPoint(x: x, y: y)
        var sz  = CGSize(width: w, height: h)
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let szVal  = AXValueCreate(.cgSize,  &sz) else { return false }
        let pOK = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
        let sOK = AXUIElementSetAttributeValue(el, kAXSizeAttribute     as CFString, szVal)
        return pOK == .success && sOK == .success
    }

    @discardableResult
    static func minimize(windowID: CGWindowID, _ value: Bool) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        return AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    static func fullscreen(windowID: CGWindowID, _ value: Bool) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        return AXUIElementSetAttributeValue(el, "AXFullScreen" as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    static func raise(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        return AXUIElementPerformAction(el, kAXRaiseAction as CFString) == .success
    }

    // Focus = activate owning app + raise the window. Without the app
    // activation the window comes forward but the app keeps prior key state.
    @discardableResult
    static func focus(windowID: CGWindowID) -> Bool {
        let target = Int(windowID)
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else { return false }
        let list = raw as! [[String: Any]]
        var foundPid: pid_t?
        for info in list {
            if let n = info[kCGWindowNumber as String] as? Int, n == target,
               let p = info[kCGWindowOwnerPID as String] as? Int {
                foundPid = pid_t(p); break
            }
        }
        guard let pid = foundPid else { return false }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        guard let el = elementFor(windowID: CGWindowID(target), pid: pid) else { return false }
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, true as CFTypeRef)
        return true
    }

    @discardableResult
    static func close(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        var btnRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, "AXCloseButton" as CFString, &btnRef) == .success,
              let btn = btnRef else { return false }
        // swiftlint:disable:next force_cast
        let button = btn as! AXUIElement
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// Current frame from AX (in the same Cocoa coords sd.windows.all returns).
    static func frame(windowID: CGWindowID) -> CGRect? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef)
        var pt = CGPoint.zero
        var sz = CGSize.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
        return CGRect(origin: pt, size: sz)
    }

    static func isMinimized(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        var ref: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &ref)
        return (ref as? Bool) ?? false
    }

    static func isFullscreen(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        var ref: AnyObject?
        AXUIElementCopyAttributeValue(el, "AXFullScreen" as CFString, &ref)
        return (ref as? Bool) ?? false
    }
}
