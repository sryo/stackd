import AppKit
import Foundation

// Per-display Spaces info via SkyLight private SPI. Same family of symbols
// hs.spaces uses (SLSCopyManagedDisplaySpaces, SLSSpaceGetType). Resolved
// at runtime via dlsym; degrades gracefully if Apple ever renames them.
enum SkyLightSpaces {
    typealias MainConnectionFn       = @convention(c) () -> Int32
    typealias CopyManagedSpacesFn    = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SpaceGetTypeFn         = @convention(c) (Int32, UInt64) -> Int32
    typealias GetActiveSpaceFn       = @convention(c) (Int32) -> UInt64

    static let handle: UnsafeMutableRawPointer? = {
        // SkyLight reliably resolves at this path on modern macOS; if Apple
        // moves it we'll fail to load and the source returns empty data.
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    static let mainConnection: MainConnectionFn? = sym("SLSMainConnectionID")
    static let copyManagedSpaces: CopyManagedSpacesFn? = sym("SLSCopyManagedDisplaySpaces")
    static let spaceGetType: SpaceGetTypeFn? = sym("SLSSpaceGetType")
    static let getActiveSpace: GetActiveSpaceFn? = sym("SLSGetActiveSpace")

    typealias CopySpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    static let copySpacesForWindows: CopySpacesForWindowsFn? = sym("SLSCopySpacesForWindows")

    static let cid: Int32 = {
        guard let fn = mainConnection else { return 0 }
        return fn()
    }()

    private static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }
}

enum Spaces {
    /// Per-screen spaces info, keyed by NSScreen UUID:
    ///   { uuid: { spaces: [id, ...], active: id|null, isFullscreen: bool } }
    static func all() -> [String: Any] {
        guard let copy = SkyLightSpaces.copyManagedSpaces,
              let getType = SkyLightSpaces.spaceGetType else {
            return [:]
        }
        let cid = SkyLightSpaces.cid
        guard let cfRef = copy(cid)?.takeRetainedValue() else { return [:] }
        let displays = cfRef as? [[String: Any]] ?? []

        // SkyLight identifies displays by either a UUID string or "Main" when
        // the "Displays Have Separate Spaces" preference is off. We rebuild a
        // UUID-keyed dict so the JS side is uniform regardless of that pref.
        let mainScreenUUID = NSScreen.screens.first.flatMap { screenUUID(for: $0) }

        var out: [String: Any] = [:]
        for disp in displays {
            var ident = (disp["Display Identifier"] as? String) ?? ""
            if ident == "Main", let main = mainScreenUUID { ident = main }
            let spacesArr = (disp["Spaces"] as? [[String: Any]]) ?? []

            var ids: [UInt64] = []
            for sp in spacesArr {
                if let n = sp["ManagedSpaceID"] as? NSNumber {
                    ids.append(n.uint64Value)
                }
            }
            let activeID = (disp["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
            let active = activeID?.uint64Value

            // SLSSpaceGetType: 0 = user, 4 = fullscreen/tiled. Mirror hs.spaces.
            var isFullscreen = false
            if let a = active {
                isFullscreen = getType(cid, a) == 4
            }

            out[ident] = [
                "spaces":       ids.map { NSNumber(value: $0) },
                "active":       active.map { NSNumber(value: $0) } as Any? ?? NSNull(),
                "isFullscreen": isFullscreen
            ]
        }
        return out
    }

    private static func screenUUID(for screen: NSScreen) -> String? {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }

    /// Spaces the given window appears on, by CGWindowID. Backed by
    /// SLSCopySpacesForWindows (private SPI). Hammerspoon exposes this as
    /// hs.spaces.windowSpaces — tilers need it to know which space a window
    /// belongs to without trusting NSScreen-derived heuristics.
    static func windowSpaces(windowID: UInt32) -> [UInt64] {
        guard let fn = SkyLightSpaces.copySpacesForWindows else { return [] }
        let cid = SkyLightSpaces.cid
        // 0x7 covers all space-set masks (current, others, fullscreen, etc.)
        let arr: CFArray = [NSNumber(value: windowID)] as CFArray
        guard let cfRef = fn(cid, 0x7, arr)?.takeRetainedValue() else { return [] }
        let nums = (cfRef as? [NSNumber]) ?? []
        return nums.map { $0.uint64Value }
    }
}

final class SpacesObserver {
    static let shared = SpacesObserver()
    private var subs: [() -> Void] = []
    private var observing = false

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        // Screen reconfig can add/remove displays, which changes the keys.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(spaceChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func spaceChanged() { fire() }

    func subscribe(_ cb: @escaping () -> Void) { subs.append(cb) }
    func unsubscribeAll() { subs.removeAll() }
    private func fire() { for cb in subs { cb() } }
}
