import CoreGraphics
import Foundation

// Window-server reads for windows stackd does not own: bounds, ordered-in
// state, level and corner radii, through SkyLight. Shared by the overlay
// tick, window motion and live-resize tracking.

// MARK: - SkyLight bindings used here

private enum SkyLightOverlay {
    typealias GetWindowBoundsFn   = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    typealias WindowIsOrderedInFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<DarwinBoolean>) -> Int32
    typealias GetWindowLevelFn    = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    typealias NewConnectionFn     = @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> Int32
    typealias WindowQueryFn       = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    typealias QueryCopyWindowsFn  = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    typealias IteratorAdvanceFn   = @convention(c) (CFTypeRef) -> Bool
    typealias IteratorAttributesFn = @convention(c) (CFTypeRef) -> UInt32
    typealias IteratorCornerRadiiFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

    static let getWindowBounds:   GetWindowBoundsFn?   = SkyLight.sym("SLSGetWindowBounds")
    static let windowIsOrderedIn: WindowIsOrderedInFn? = SkyLight.sym("SLSWindowIsOrderedIn")
    static let getWindowLevel:    GetWindowLevelFn?    = SkyLight.sym("SLSGetWindowLevel")
    static let newConnection:     NewConnectionFn?     = SkyLight.sym("SLSNewConnection")
    static let windowQuery:       WindowQueryFn?       = SkyLight.sym("SLSWindowQueryWindows")
    static let queryCopyWindows:  QueryCopyWindowsFn?  = SkyLight.sym("SLSWindowQueryResultCopyWindows")
    static let iteratorAdvance:   IteratorAdvanceFn?   = SkyLight.sym("SLSWindowIteratorAdvance")
    static let iteratorAttributes: IteratorAttributesFn? = SkyLight.sym("SLSWindowIteratorGetAttributes")
    // macOS 26 and later.
    static let iteratorCornerRadii: IteratorCornerRadiiFn? = SkyLight.sym("SLSWindowIteratorGetCornerRadii")
}

// Signatures per yabai/src/misc/extern.h. Both return a +1 display
// identifier: a display UUID string, or "Main" when the window server has
// no per-display answer.
private enum SkyLightWindowDisplay {
    typealias CopyManagedDisplayForWindowFn   = @convention(c) (Int32, UInt32) -> Unmanaged<CFString>?
    typealias CopyBestManagedDisplayForRectFn = @convention(c) (Int32, CGRect) -> Unmanaged<CFString>?

    static let forWindow: CopyManagedDisplayForWindowFn?   = SkyLight.sym("SLSCopyManagedDisplayForWindow")
    static let forRect:   CopyBestManagedDisplayForRectFn? = SkyLight.sym("SLSCopyBestManagedDisplayForRect")
}

/// The window server's own answer to "which display is this on", as the
/// display identifier it files the window's space under.
enum WindowServerDisplay {
    /// nil when the SPI is missing or `wid` is 0.
    static func identifier(ofWindow wid: CGWindowID) -> String? {
        guard wid != 0, let fn = SkyLightWindowDisplay.forWindow else { return nil }
        return fn(Overlay.readConnection, UInt32(wid))?.takeRetainedValue() as String?
    }

    /// The display the window server would place `rect` (top-left global
    /// coordinates) on. nil when the SPI is missing.
    static func identifier(bestFor rect: CGRect) -> String? {
        guard let fn = SkyLightWindowDisplay.forRect else { return nil }
        return fn(Overlay.readConnection, rect)?.takeRetainedValue() as String?
    }
}

/// Per-window attributes from an SLSWindowQueryWindows iterator.
enum OverlayWindowQuery {
    /// Set exactly while the window is ordered in: cleared by minimize,
    /// app hide and orderOut, the same states SLSWindowIsOrderedIn reports.
    static let orderedInAttribute: UInt32 = 0x2

    static func isOrderedIn(attributes: UInt32) -> Bool {
        attributes & orderedInAttribute != 0
    }
}

extension Overlay {
    /// The window-server connection the reads below go through: a second one,
    /// owning no windows, falling back to the main connection when SkyLight
    /// won't open it. Some reads first wait until the server has applied
    /// every transaction the connection committed; on the main connection
    /// that includes the panels' own moves and resizes, which the server can
    /// hold for about half a second while the target's app commits animated
    /// frames, so a per-tick read there stalls the main thread and the motion
    /// engine with it. SLSWindowIsOrderedIn and CGWindowListCopyWindowInfo
    /// always wait on the main connection, whatever connection they are
    /// given.
    static let readConnection: Int32 = {
        // Opened before the main connection exists, a new connection would
        // become the main one.
        let main = SkyLight.cid
        var cid: Int32 = 0
        if let fn = SkyLightOverlay.newConnection, fn(0, &cid) == 0, cid != 0, cid != main { return cid }
        return main
    }()

    /// Read the current bounds of a window we don't own. Top-left origin,
    /// screen-points. Returns nil if the wid is unknown or SLS rejects it.
    static func bounds(of wid: CGWindowID) -> CGRect? {
        guard let fn = SkyLightOverlay.getWindowBounds else { return nil }
        var frame = CGRect.zero
        let err = fn(readConnection, UInt32(wid), &frame)
        return err == 0 ? frame : nil
    }

    /// Is the window currently ordered-in (visible)? Used by Bridge to
    /// suppress the per-tick reposition on minimized / hidden targets
    /// without tearing down the overlay.
    static func isOrderedIn(_ wid: CGWindowID) -> Bool {
        guard wid != 0 else { return false }
        if let query = SkyLightOverlay.windowQuery,
           let copyWindows = SkyLightOverlay.queryCopyWindows,
           let advance = SkyLightOverlay.iteratorAdvance,
           let attributes = SkyLightOverlay.iteratorAttributes {
            // SLSWindowIsOrderedIn always synchronizes the main connection
            // first (see readConnection); a query synchronizes only the
            // connection it runs on.
            var n = Int32(bitPattern: wid)
            guard let number = CFNumberCreate(nil, .sInt32Type, &n),
                  let result = query(readConnection, [number] as CFArray, 1)?.takeRetainedValue(),
                  let windows = copyWindows(result)?.takeRetainedValue(),
                  advance(windows) else { return false }
            return OverlayWindowQuery.isOrderedIn(attributes: attributes(windows))
        }
        guard let fn = SkyLightOverlay.windowIsOrderedIn else { return false }
        var shown: DarwinBoolean = false
        _ = fn(SkyLight.cid, UInt32(wid), &shown)
        return shown.boolValue
    }

    /// The window-server level of a window we don't own (the raw
    /// NSWindow.Level / CGWindowLevel value). nil if SLS rejects the wid.
    static func level(of wid: CGWindowID) -> Int? {
        guard wid != 0, let fn = SkyLightOverlay.getWindowLevel else { return nil }
        var level: Int32 = 0
        return fn(readConnection, UInt32(wid), &level) == 0 ? Int(level) : nil
    }

    /// The corner radii the window server rounds a window we don't own with,
    /// in points: four values, 0 for square corners. nil when the wid is
    /// unknown or the OS predates the call (macOS 26).
    static func cornerRadii(of wid: CGWindowID) -> [Double]? {
        guard wid != 0,
              let query = SkyLightOverlay.windowQuery,
              let copyWindows = SkyLightOverlay.queryCopyWindows,
              let advance = SkyLightOverlay.iteratorAdvance,
              let radii = SkyLightOverlay.iteratorCornerRadii else { return nil }
        var n = Int32(bitPattern: wid)
        guard let number = CFNumberCreate(nil, .sInt32Type, &n),
              let result = query(readConnection, [number] as CFArray, 1)?.takeRetainedValue(),
              let windows = copyWindows(result)?.takeRetainedValue(),
              advance(windows),
              let values = radii(windows)?.takeRetainedValue() as? [NSNumber],
              !values.isEmpty else { return nil }
        return values.map(\.doubleValue)
    }
}
