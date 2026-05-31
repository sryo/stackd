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
        let nc = NotificationCenter.default
        let screenToken = nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.fire() }

        // Brightness has no notification; poll every 2s while at least one
        // stack subscribes. Bridge's lastDisplay JSON dedup absorbs no-ops.
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(timer, forMode: .common)

        return Token {
            nc.removeObserver(screenToken)
            timer.invalidate()
        }
    }
}
