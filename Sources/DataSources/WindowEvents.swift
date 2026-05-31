import AppKit
import CoreGraphics
import Foundation

// Window-level CGS notifications via SkyLight private SPI.
//
// Extends the connection-notify infrastructure already proven in
// Sources/DataSources/Spaces.swift (which subscribes to space-life events
// 1327/1328/1204). We use the sibling `SLSRegisterNotifyProc` entry point
// (not the per-connection variant) so we observe events for windows owned by
// other applications, matching JankyBorders' approach.
//
// Coexistence with WindowsLifecycleObserver (1Hz CGWindowList poll):
//   Both run. CGS fires earlier/faster than the poll; the poller is the
//   conservative backstop. Stack manifests subscribe via `handles: ["sd.window.*"]`
//   to whichever bang they care about — `sd.window.created` may fire from
//   either source first. The polling observer's per-tick diff sees an already-
//   existing window on the next tick and skips, so the duplicate is naturally
//   suppressed.
//
// Event-ID source of truth & verified availability:
//   The IDs below are taken from FelixKratz/JankyBorders (events.h) cross-
//   referenced with koekeishiya/yabai (yabai.c registers 808/1327/1328/1204
//   via SLSRegisterConnectionNotifyProc with the same wire format).
//
//   On macOS 26 (Tahoe) we have CONFIRMED, via the STACKD_CGS_DEBUG=1 dump
//   loop below, that these IDs fire reliably:
//
//     1325 — window created               (verified, payload {sid, wid})
//     1326 — window destroyed             (verified, payload {sid, wid})
//     1508 — frontmost app changed        (verified, empty payload — surfaced
//                                          as sd.window.focusedByMouse)
//     1327 — space created                (already wired in Spaces.swift;
//                                          ALSO fires on minimize on Tahoe
//                                          because each minimize creates a
//                                          per-window background space)
//
//   The remaining IDs (804/806/807/808/815/816) were live on Sequoia and
//   earlier but DO NOT fire on Tahoe as of macOS 26.5. The Tahoe equivalent
//   appears to ride generic mouse-event IDs 718/719 with a 248-byte payload
//   that does NOT carry a CGWindowID at offset 0 — that's an input-tap
//   surface, not a per-window CGS event. Registrations for the missing IDs
//   are kept below as no-ops so they Just Work if a future macOS release
//   re-exposes them; symptom of "missing" today is silent no-fire.
//
//   To rediscover IDs after a macOS bump: launch the daemon with
//   STACKD_CGS_DEBUG=1; every event in [700, 2000) is logged to stderr with
//   ID + first 32 bytes of payload. Trigger the action you want to map,
//   look for an event whose hex payload starts with the affected window's
//   CGWindowID in little-endian.

private enum SkyLightWindowEvents {
    typealias MainConnectionFn      = @convention(c) () -> Int32
    // SLSRegisterNotifyProc — JankyBorders/yabai use this for per-window
    // events. Callback signature: (event, data, dataLength, context). NO
    // connection id is passed (unlike SLSRegisterConnectionNotifyProc which
    // we use for space events in Spaces.swift). This is the right entry
    // point for events that should fire globally for ALL windows of ALL
    // applications, not just our own connection.
    typealias CGSNotifyCallback     = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    typealias RegisterNotifyProcFn  = @convention(c) (CGSNotifyCallback, UInt32, UnsafeMutableRawPointer?) -> Int32

    static let mainConnection:     MainConnectionFn?     = SkyLight.sym("SLSMainConnectionID")
    static let registerNotifyProc: RegisterNotifyProcFn? = SkyLight.sym("SLSRegisterNotifyProc")

    static let cid: Int32 = mainConnection?() ?? 0
}

// CGS window event IDs. JankyBorders/events.h is the canonical reference for
// the names; macOS 26.5 (Tahoe) availability per the STACKD_CGS_DEBUG dump.
//   804  — window closed         (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   806  — window moved          (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   807  — window resized        (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   808  — window reordered      (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   815  — window deminimized    (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   816  — window minimized      (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   1325 — window created        (ACTIVE on Tahoe; payload: { uint64 sid; uint32 wid })
//   1326 — window destroyed      (ACTIVE on Tahoe; payload: { uint64 sid; uint32 wid })
//   1508 — frontmost app changed (ACTIVE on Tahoe; no payload; surfaced as
//                                 sd.window.focusedByMouse since front-change
//                                 is the closest stable signal for "user
//                                 clicked to focus a different window" — the
//                                 nominal 1300/kCGSEventWindowFocusedByMouse
//                                 doesn't fire on current macOS)
private let kSDWindowClosed:        UInt32 = 804
private let kSDWindowMoved:         UInt32 = 806
private let kSDWindowResized:       UInt32 = 807
private let kSDWindowReordered:     UInt32 = 808
private let kSDWindowDeminimized:   UInt32 = 815
private let kSDWindowMinimized:     UInt32 = 816
private let kSDWindowCreated:       UInt32 = 1325
private let kSDWindowDestroyed:     UInt32 = 1326
private let kSDWindowFocusedByMouse: UInt32 = 1508

// The shared callback. SkyLight invokes us off the main thread; we hop to main
// before touching AppDelegate.shared / host so bang dispatch and WebView fan-out
// stay on the runloop they were built on.
//
// Payload decode rules:
//   - Create / Destroy (1325/1326): { uint64_t sid; uint32_t wid; }
//   - Front-change (1508): no payload data we use
//   - All other window events: uint32_t wid at offset 0
//
// dataLen is always >= the size we read; we sanity-check before dereferencing
// because SkyLight has been known to fire callbacks with zero-length payloads
// during edge cases (e.g. a window getting created+destroyed in the same tick).
private let windowEventsCallback: SkyLightWindowEvents.CGSNotifyCallback = { eventType, data, dataLen, _ in
    // Front-change has no useful payload; just fire the bang.
    if eventType == kSDWindowFocusedByMouse {
        DispatchQueue.main.async {
            AppDelegate.shared?.host?.bang(name: "sd.window.focusedByMouse", detail: [:])
        }
        return
    }

    // Create / Destroy carry a {sid, wid} struct. wid is at offset 8.
    if eventType == kSDWindowCreated || eventType == kSDWindowDestroyed {
        guard let data = data, dataLen >= 12 else { return }
        let wid = data.advanced(by: 8).load(as: UInt32.self)
        WindowEvents.handleSpawn(eventType: eventType, wid: wid)
        return
    }

    // All remaining window events start with a uint32_t wid.
    guard let data = data, dataLen >= 4 else { return }
    let wid = data.load(as: UInt32.self)
    WindowEvents.handleModify(eventType: eventType, wid: wid)
}

// Debug logger: prints every event ID + first 32 bytes of payload to stderr.
// Active only when STACKD_CGS_DEBUG=1. Used to verify event-ID mappings after
// a macOS version bump.
private let debugWindowEventsCallback: SkyLightWindowEvents.CGSNotifyCallback = { event, data, dataLen, _ in
    var hex = ""
    if let data = data, dataLen > 0 {
        let lim = min(dataLen, 32)
        for i in 0..<lim {
            hex += String(format: "%02x ", data.advanced(by: i).load(as: UInt8.self))
        }
    }
    FileHandle.standardError.write(Data("stackd-cgs: event=\(event) len=\(dataLen) [\(hex)]\n".utf8))
}

enum WindowEvents {
    private static var cgsRegistered = false

    /// Install the CGS callbacks. Idempotent; safe to call from AppDelegate.
    /// SkyLight has no removeNotifyProc, so registration lives for the lifetime
    /// of the process — matches the SpacesObserver pattern.
    static func install() {
        guard !cgsRegistered, let reg = SkyLightWindowEvents.registerNotifyProc else { return }
        for evt in [
            kSDWindowClosed,
            kSDWindowMoved,
            kSDWindowResized,
            kSDWindowReordered,
            kSDWindowDeminimized,
            kSDWindowMinimized,
            kSDWindowCreated,
            kSDWindowDestroyed,
            kSDWindowFocusedByMouse
        ] {
            _ = reg(windowEventsCallback, evt, nil)
        }
        // Debug-watcher: STACKD_CGS_DEBUG=1 registers a logger for every event
        // ID in [700, 2000) so we can rediscover IDs after a macOS shift.
        // Mirrors the JankyBorders debug loop in src/events.c.
        if ProcessInfo.processInfo.environment["STACKD_CGS_DEBUG"] != nil {
            for i in UInt32(700)..<UInt32(2000) {
                _ = reg(debugWindowEventsCallback, i, nil)
            }
        }
        cgsRegistered = true
    }

    // MARK: - Bang fan-out

    /// Per-window bangs that just need an id. Frame is recovered via
    /// WindowsByID.frame(windowID:) for move/resize so consumers don't have to
    /// query separately; for the others id alone is enough.
    fileprivate static func handleModify(eventType: UInt32, wid: UInt32) {
        DispatchQueue.main.async {
            guard let host = AppDelegate.shared?.host else { return }

            switch eventType {
            case kSDWindowMoved:
                var d: [String: Any] = ["id": Int(wid)]
                if let f = WindowsByID.frame(windowID: CGWindowID(wid)) {
                    d["frame"] = frameDict(f)
                }
                host.bang(name: "sd.window.moved", detail: d)

            case kSDWindowResized:
                var d: [String: Any] = ["id": Int(wid)]
                if let f = WindowsByID.frame(windowID: CGWindowID(wid)) {
                    d["frame"] = frameDict(f)
                }
                host.bang(name: "sd.window.resized", detail: d)

            case kSDWindowReordered:
                host.bang(name: "sd.window.reordered", detail: ["id": Int(wid)])

            case kSDWindowMinimized:
                host.bang(name: "sd.window.minimized", detail: ["id": Int(wid)])

            case kSDWindowDeminimized:
                host.bang(name: "sd.window.deminimized", detail: ["id": Int(wid)])

            case kSDWindowClosed:
                // Treat 804 as a destroyed-window signal so consumers don't
                // have to track two near-identical events. The polling
                // WindowsLifecycleObserver will independently fire its own
                // sd.window.destroyed on next tick — host.bang's per-stack
                // dedup is the stack author's responsibility, but in practice
                // the polling diff sees the window already gone and skips.
                WindowsByID.invalidateAll()
                host.bang(name: "sd.window.destroyed", detail: ["id": Int(wid)])

            default:
                break
            }
        }
    }

    /// Create/Destroy carry a window id; we look up app/pid/title via
    /// CGWindowListCopyWindowInfo filtered by kCGWindowNumber so the detail
    /// matches the polling observer's payload shape.
    fileprivate static func handleSpawn(eventType: UInt32, wid: UInt32) {
        DispatchQueue.main.async {
            guard let host = AppDelegate.shared?.host else { return }

            switch eventType {
            case kSDWindowCreated:
                let detail = detailForWindow(wid: wid)
                host.bang(name: "sd.window.created", detail: detail)

            case kSDWindowDestroyed:
                // The window is already gone — CGWindowList lookup will miss.
                // Emit just the id; consumers that need the prior title/app
                // should cache from the create event. Mirrors yabai's
                // SLS_WINDOW_DESTROYED handler.
                WindowsByID.invalidateAll()
                host.bang(name: "sd.window.destroyed", detail: ["id": Int(wid)])

            default:
                break
            }
        }
    }

    // MARK: - Helpers

    private static func frameDict(_ f: CGRect) -> [String: Int] {
        [
            "x": Int(f.origin.x), "y": Int(f.origin.y),
            "w": Int(f.size.width), "h": Int(f.size.height)
        ]
    }

    /// Build a sd.window.created detail dict via CGWindowList lookup. One CG
    /// call per creation is fine — events fire on the order of one per app
    /// launch / new-window, not per frame.
    private static func detailForWindow(wid: UInt32) -> [String: Any] {
        var out: [String: Any] = ["id": Int(wid)]
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], CGWindowID(wid)
        ) else { return out }
        let list = raw as! [[String: Any]]
        guard let info = list.first else { return out }

        out["app"]   = (info[kCGWindowOwnerName as String] as? String) ?? ""
        out["pid"]   = (info[kCGWindowOwnerPID  as String] as? Int) ?? 0
        out["title"] = (info[kCGWindowName as String] as? String) ?? ""
        if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] {
            out["frame"] = [
                "x": Int(bounds["X"] ?? 0),
                "y": Int(bounds["Y"] ?? 0),
                "w": Int(bounds["Width"] ?? 0),
                "h": Int(bounds["Height"] ?? 0)
            ]
        }
        return out
    }
}
