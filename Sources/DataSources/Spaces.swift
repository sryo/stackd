import AppKit
import Foundation

// Per-display Spaces info via SkyLight private SPI. Same family of symbols
// hs.spaces uses (SLSCopyManagedDisplaySpaces, SLSSpaceGetType). Shared
// SkyLight loader lives in Sources/Private/SkyLight.swift; this enum just
// declares the symbol surface this domain needs.
private enum SkyLightSpaces {
    typealias CopyManagedSpacesFn    = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SpaceGetTypeFn         = @convention(c) (Int32, UInt64) -> Int32
    typealias GetActiveSpaceFn       = @convention(c) (Int32) -> UInt64
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?

    // SLSRegisterConnectionNotifyProc(cid, callback, eventType, context). Used
    // for kCGSEvent space-life notifs that NSWorkspace doesn't surface. Yabai's
    // src/yabai.c is the reference for the exact signature.
    typealias CGSConnectionCallback = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    typealias RegisterNotifyProcFn  = @convention(c) (Int32, CGSConnectionCallback, UInt32, UnsafeMutableRawPointer?) -> Int32

    static let copyManagedSpaces:    CopyManagedSpacesFn?    = SkyLight.sym("SLSCopyManagedDisplaySpaces")
    static let spaceGetType:         SpaceGetTypeFn?         = SkyLight.sym("SLSSpaceGetType")
    static let getActiveSpace:       GetActiveSpaceFn?       = SkyLight.sym("SLSGetActiveSpace")
    static let copySpacesForWindows: CopySpacesForWindowsFn? = SkyLight.sym("SLSCopySpacesForWindows")
    static let registerNotifyProc:   RegisterNotifyProcFn?   = SkyLight.sym("SLSRegisterConnectionNotifyProc")
}

enum Spaces {
    /// Per-screen spaces info, keyed by NSScreen UUID:
    ///   { uuid: { spaces: [id, ...], active: id|null, isFullscreen: bool } }
    static func all() -> [String: Any] {
        guard let copy = SkyLightSpaces.copyManagedSpaces,
              let getType = SkyLightSpaces.spaceGetType else {
            return [:]
        }
        let cid = SkyLight.cid
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
        let cid = SkyLight.cid
        // 0x7 covers all space-set masks (current, others, fullscreen, etc.)
        let arr: CFArray = [NSNumber(value: windowID)] as CFArray
        guard let cfRef = fn(cid, 0x7, arr)?.takeRetainedValue() else { return [] }
        let nums = (cfRef as? [NSNumber]) ?? []
        return nums.map { $0.uint64Value }
    }

    /// CGWindowIDs of all currently MINIMIZED windows on `spaceID`. Used by
    /// WindowScape's "where did I minimize this?" recall, and by future
    /// snapshot/restore code.
    ///
    /// Path chosen: CGWindowList(.optionAll) → filter `kCGWindowIsOnscreen == 0`
    /// → cross-reference each candidate with `windowSpaces(windowID:)`.
    /// SLSCopyWindowsWithOptionsAndTags is the more direct SLS route (yabai
    /// uses it with options=0x7 for "include minimized") but its set_tags /
    /// clear_tags out-parameter pair is easy to get wrong from Swift and the
    /// minimized bit isn't directly selectable — you'd still need a second
    /// pass against options=0x2 to subtract on-screen windows. The CG +
    /// windowSpaces route stays on public API for the heavy lift and only
    /// uses SLS for the per-window space lookup we already vend.
    static func minimizedWindows(spaceID: UInt64) -> [UInt32] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) else { return [] }
        let list = raw as! [[String: Any]]
        var out: [UInt32] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = info[kCGWindowNumber as String] as? Int else { continue }
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Int) ?? 0
            if onscreen != 0 { continue }
            let wid = UInt32(num)
            if windowSpaces(windowID: wid).contains(spaceID) {
                out.append(wid)
            }
        }
        return out
    }
}

// CGS event types observed below. Yabai's src/yabai.c is the reference for
// which IDs are live on shipping macOS:
//   1327 — space created
//   1328 — space destroyed
//   1204 — Mission Control entered (proxy for the user-driven space re-order
//          interaction that NSWorkspace's activeSpaceDidChange doesn't fire on
//          when no active-space change happens)
//
// SkyLight exposes no public "remove notify" entry point, so once registered
// the callback lives for the process. We guard registration with a static
// flag and route into the singleton; Token cancel only tears down the
// NSWorkspace / NSApplication observers (the CGS callback no-ops once
// SpacesObserver has no subscribers because fire() iterates an empty subs
// dict).
private let kCGSEventSpaceCreated:        UInt32 = 1327
private let kCGSEventSpaceDestroyed:      UInt32 = 1328
private let kCGSEventMissionControlEnter: UInt32 = 1204

private let spacesCGSCallback: SkyLightSpaces.CGSConnectionCallback = { eventType, _, _, _, _ in
    DispatchQueue.main.async {
        SpacesObserver.shared.fire()
        // 1204 is the only CGS signal for "Mission Control entered" — exit is
        // an AX notification on the Dock, handled in MissionControl.swift.
        if eventType == kCGSEventMissionControlEnter {
            AppDelegate.shared?.host?.bang(name: "sd.missionControl.entered", detail: [:])
        }
    }
}

final class SpacesObserver: RefCountedObserver {
    static let shared = SpacesObserver()
    private override init() { super.init() }

    private static var cgsRegistered = false

    override func install() -> Token {
        // Screen reconfig can add/remove displays, which changes the keys —
        // observe alongside activeSpaceDidChange.
        let ncToken = installNotifications([
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        ])

        if !SpacesObserver.cgsRegistered,
           let reg = SkyLightSpaces.registerNotifyProc {
            let cid = SkyLight.cid
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceCreated,        nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceDestroyed,      nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventMissionControlEnter, nil)
            SpacesObserver.cgsRegistered = true
        }

        return ncToken
    }
}
