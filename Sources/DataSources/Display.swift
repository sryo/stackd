import AppKit
import CoreGraphics

// Per-display info + brightness. Brightness on Apple Silicon's built-in
// display requires the private DisplayServices framework — loaded via
// dlopen so a missing framework degrades to nil instead of failing the build.
// External-display brightness control (DDC/CI) is out of scope; that's
// Lunar's job, not the daemon's.

enum Display {
    static func all() -> [[String: Any]] {
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return [
                "displayID":    Int(id),
                "uuid":         uuidString(for: id) ?? "",
                "name":         screen.localizedName,
                "frame":        rect(screen.frame),
                "visibleFrame": rect(screen.visibleFrame),
                "scale":        screen.backingScaleFactor,
                "builtin":      CGDisplayIsBuiltin(id) != 0,
                "brightness":   brightness(of: id) as Any? ?? NSNull()
            ]
        }
    }

    static func brightness(of displayID: CGDirectDisplayID) -> Float? {
        guard let getter = DisplayServicesShim.getBrightness else { return nil }
        var v: Float = 0
        return getter(displayID, &v) == 0 ? v : nil
    }

    @discardableResult
    static func setBrightness(displayID: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setter = DisplayServicesShim.setBrightness else { return false }
        let clamped: Float = max(0, min(1, value))
        return setter(displayID, clamped) == 0
    }

    private static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String?
    }

    private static func rect(_ r: CGRect) -> [String: Int] {
        ["x": Int(r.origin.x), "y": Int(r.origin.y),
         "w": Int(r.size.width), "h": Int(r.size.height)]
    }
}

/// Resolves DisplayServices private SPI at runtime. Returns nil getters/setters
/// if the framework isn't loadable on this machine.
enum DisplayServicesShim {
    typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    }()

    static let setBrightness: SetBrightnessFn? = {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: SetBrightnessFn.self)
    }()

    static let getBrightness: GetBrightnessFn? = {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightnessFn.self)
    }()
}

final class DisplayObserver: RefCountedObserver {
    static let shared = DisplayObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let ncToken = installNotifications([
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        ])

        // Brightness has no notification; poll every 2s while at least one
        // stack subscribes. Bridge's lastDisplay JSON dedup absorbs no-ops.
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(timer, forMode: .common)

        return Token {
            ncToken.cancel()
            timer.invalidate()
        }
    }
}

// MARK: - Display hotplug bangs
//
// Lifecycle bangs (`sd.display.added`, `sd.display.removed`,
// `sd.display.reconfigured`) fan out to stacks that declare them in
// `handles`. Installed once at startup from AppDelegate — same shape as
// WindowEvents.install() — so the bangs fire even with no `sd.display`
// subscriber.
//
// `CGDisplayRegisterReconfigurationCallback` (public CoreGraphics API) fires
// twice per change: a pre-pass with `.beginConfigurationFlag` only, then a
// post-pass with the resolved flags. We ignore the pre-pass and fan out on
// the second call so consumers see one bang per change.
enum DisplayHotplug {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        CGDisplayRegisterReconfigurationCallback(displayHotplugCallback, nil)
        installed = true
    }
}

private let displayHotplugCallback: CGDisplayReconfigurationCallBack = { displayID, flags, _ in
    if flags.contains(.beginConfigurationFlag) { return }

    DispatchQueue.main.async {
        guard let host = AppDelegate.shared?.host else { return }
        let detail: [String: Any] = ["displayID": Int(displayID)]

        if flags.contains(.addFlag) {
            host.bang(name: "sd.display.added", detail: detail)
            return
        }
        if flags.contains(.removeFlag) {
            host.bang(name: "sd.display.removed", detail: detail)
            return
        }
        // Anything else worth surfacing — move, mode change, mirror, rotation,
        // set-main, desktop reshape — collapses to `reconfigured` so consumers
        // have one channel to react to. If none of those bits is set the
        // notification is a no-op (e.g. begin pass already filtered above).
        let reconfigured: CGDisplayChangeSummaryFlags = [
            .movedFlag, .setMainFlag, .setModeFlag, .enabledFlag,
            .disabledFlag, .mirrorFlag, .unMirrorFlag, .desktopShapeChangedFlag
        ]
        if !flags.intersection(reconfigured).isEmpty {
            host.bang(name: "sd.display.reconfigured", detail: detail)
        }
    }
}
