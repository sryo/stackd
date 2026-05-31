import AppKit
import Foundation

// Per-display Spaces info via SkyLight private SPI. Same family of symbols
// hs.spaces uses (SLSCopyManagedDisplaySpaces, SLSSpaceGetType). Shared
// SkyLight loader lives in Sources/Private/SkyLight.swift; this enum just
// declares the symbol surface this domain needs.
private enum SkyLightSpaces {
    typealias MainConnectionFn       = @convention(c) () -> Int32
    typealias CopyManagedSpacesFn    = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SpaceGetTypeFn         = @convention(c) (Int32, UInt64) -> Int32
    typealias GetActiveSpaceFn       = @convention(c) (Int32) -> UInt64
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?

    static let mainConnection:       MainConnectionFn?       = SkyLight.sym("SLSMainConnectionID")
    static let copyManagedSpaces:    CopyManagedSpacesFn?    = SkyLight.sym("SLSCopyManagedDisplaySpaces")
    static let spaceGetType:         SpaceGetTypeFn?         = SkyLight.sym("SLSSpaceGetType")
    static let getActiveSpace:       GetActiveSpaceFn?       = SkyLight.sym("SLSGetActiveSpace")
    static let copySpacesForWindows: CopySpacesForWindowsFn? = SkyLight.sym("SLSCopySpacesForWindows")

    static let cid: Int32 = mainConnection?() ?? 0
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

final class SpacesObserver: RefCountedObserver {
    static let shared = SpacesObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let appCenter = NotificationCenter.default
        let t1 = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.fire() }
        // Screen reconfig can add/remove displays, which changes the keys.
        let t2 = appCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.fire() }
        return Token {
            workspaceCenter.removeObserver(t1)
            appCenter.removeObserver(t2)
        }
    }
}
