import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Display
//
// Per-display info + brightness. Brightness on Apple Silicon's built-in
// display requires the private DisplayServices framework — loaded via
// dlopen so a missing framework degrades to nil instead of failing the build.
//
// External-display brightness uses DDC/CI over the IOAVService private
// SPI; see DisplayDDC.swift. setBrightness routes by CGDisplayIsBuiltin —
// internal hits DisplayServices, external hits DDC. Both code paths
// degrade to a `false` return if the underlying SPI doesn't load.

enum Display {
    // `frame`/`visibleFrame` are serialized as CG top-left to match every other
    // xy in `sd.*` (sd.mouse, sd.cursor, eventtap, hotcorners, sd.windows.*).
    // NSScreen.frame is bottom-left; CGDisplayBounds is top-left. We carry the
    // dock/menu-bar insets across by diffing the two NSScreen rects.
    static func all() -> [[String: Any]] {
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let cgFrame = CGDisplayBounds(id)
            let nsFrame = screen.frame
            let nsVisible = screen.visibleFrame
            let topInset    = max(0, nsFrame.maxY - nsVisible.maxY)
            let bottomInset = max(0, nsVisible.minY - nsFrame.minY)
            let leftInset   = max(0, nsVisible.minX - nsFrame.minX)
            let rightInset  = max(0, nsFrame.maxX - nsVisible.maxX)
            let cgVisible = CGRect(
                x: cgFrame.minX + leftInset,
                y: cgFrame.minY + topInset,
                width:  max(0, cgFrame.width  - leftInset - rightInset),
                height: max(0, cgFrame.height - topInset  - bottomInset)
            )
            return [
                "displayID":    Int(id),
                "uuid":         uuidString(for: id) ?? "",
                "name":         screen.localizedName,
                "frame":        rect(cgFrame),
                "visibleFrame": rect(cgVisible),
                "scale":        screen.backingScaleFactor,
                "builtin":      CGDisplayIsBuiltin(id) != 0,
                "brightness":   brightness(of: id) as Any? ?? NSNull()
            ]
        }
    }

    static func brightness(of displayID: CGDirectDisplayID) -> Float? {
        // Built-in panel: DisplayServices reports a normalized 0..1 directly.
        // External: DDC-CI VCP read returns an integer 0..100 (and many
        // monitors don't actually implement the read side, so this often
        // returns nil — JS surfaces that as null and the UI falls back to
        // an optimistic local value).
        if CGDisplayIsBuiltin(displayID) != 0 {
            guard let getter = DisplayServicesShim.getBrightness else { return nil }
            var v: Float = 0
            return getter(displayID, &v) == 0 ? v : nil
        }
        guard let pct = DisplayDDC.getBrightness(displayID: displayID) else { return nil }
        return Float(pct) / 100.0
    }

    @discardableResult
    static func setBrightness(displayID: CGDirectDisplayID, _ value: Float) -> Bool {
        let clamped: Float = max(0, min(1, value))
        if CGDisplayIsBuiltin(displayID) != 0 {
            // Internal display: CoreDisplay/DisplayServices SPI. Takes the
            // normalized 0..1 value as-is — no I²C round-trip.
            guard let setter = DisplayServicesShim.setBrightness else { return false }
            return setter(displayID, clamped) == 0
        }
        // External display: VESA MCCS brightness over DDC/CI. v1 assumes
        // the monitor uses a 0..100 scale (the common case); monitors that
        // declare a larger max via the capabilities string will see this
        // as "always low" until a v2 caps-string fetch lands.
        let percent = Int((clamped * 100).rounded())
        return DisplayDDC.setBrightness(displayID: displayID, percent: percent)
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

        // Brightness-change distributed notifications. The macOS bezel UI
        // (the small overlay that appears when you press F1/F2 or move the
        // brightness slider in System Settings) posts a DN that we can hook
        // for instant pushes. Multiple names because the bezel implementation
        // moved between BezelServices and BezelUI across macOS versions —
        // observing all known names is cheap and covers both paths.
        //
        // Programmatic brightness changes that bypass the bezel still need
        // the safety-net poll below; on a typical Mac, F1/F2 + System
        // Settings cover ~all user-driven brightness changes, so the live
        // path handles the cases the user actually notices.
        let dn = DistributedNotificationCenter.default()
        let brightnessTokens: [(NSObjectProtocol)] = [
            "com.apple.BezelUI.BSBrightnessNotification",
            "com.apple.BezelServices.BSBrightnessNotification",
            "com.apple.brightness.changed",
        ].map { name in
            dn.addObserver(forName: Notification.Name(name),
                           object: nil, queue: .main) { [weak self] _ in
                self?.fire()
            }
        }

        // Safety net: 1s poll (tightened from 2s). Catches programmatic
        // brightness changes that bypass the bezel notifications + drives
        // external-display readings (DDC-CI brightness can't be observed).
        // Bridge's lastDisplay JSON dedup absorbs no-ops, so the cost when
        // brightness is stable is one CGDirectDisplay read + a hash compare.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(timer, forMode: .common)

        return Token {
            ncToken.cancel()
            for t in brightnessTokens { dn.removeObserver(t) }
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

// MARK: - DisplayLink
//
// CVDisplayLink-driven push channel. Fires at the display's vsync rate
// (60 Hz standard, 120 Hz ProMotion) — cheaper + smoother than rAF inside
// a heavy WebView, and aligned to the compositor's flip cadence which is
// what sd.overlay's CG context flushes need to avoid tearing.
//
// Consumers:
//  - sd.overlay (planned) — needs vsync-aligned flush
//  - any Canvas-heavy stack that wants ProMotion-rate ticks without
//    fighting rAF throttling inside a backgrounded WebView

enum DisplayLink {
    /// Most-recent frame snapshot. Nil before the first vsync arrives.
    static func snapshot() -> [String: Any]? {
        DisplayLinkObserver.shared.snapshot()
    }
}

// Top-level C-convention callback. CVDisplayLinkOutputCallback's signature
// can't be satisfied by a Swift closure without going through a thunk; the
// refcon recovers the singleton without resorting to globals. Fires on a
// private CV thread — we update the snapshot under the lock then hop to
// main to call fire() so JS dispatch stays on one queue.
private func displayLinkCallback(
    _ link: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ displayLinkContext: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx = displayLinkContext else { return kCVReturnSuccess }
    let observer = Unmanaged<DisplayLinkObserver>.fromOpaque(ctx).takeUnretainedValue()

    // videoRefreshPeriod / videoTimeScale = seconds per refresh; invert for Hz.
    // Falls back to the configured nominal period if videoRefreshPeriod is
    // zero (some virtualized / mirrored configurations report 0 here).
    let out = inOutputTime.pointee
    let period = Double(out.videoRefreshPeriod)
    let scale = Double(out.videoTimeScale)
    let refreshRate: Double
    if period > 0 && scale > 0 {
        refreshRate = scale / period
    } else {
        let nominal = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        let nominalSeconds = Double(nominal.timeValue) / Double(nominal.timeScale)
        refreshRate = nominalSeconds > 0 ? 1.0 / nominalSeconds : 60.0
    }

    observer.acceptFrame(
        timestamp: CFAbsoluteTimeGetCurrent(),
        refreshRate: refreshRate
    )
    return kCVReturnSuccess
}

final class DisplayLinkObserver: RefCountedObserver {
    static let shared = DisplayLinkObserver()
    private override init() { super.init() }

    private var link: CVDisplayLink?
    private let lock = NSLock()
    private var current: (timestamp: Double, frame: Int, refreshRate: Double)?
    private var frameCounter: Int = 0

    // Keeps the singleton retained through Unmanaged.passRetained so the
    // displayLinkContext pointer is always valid for the lifetime of the
    // active link. Balanced by release() in teardown.
    private var refconRetainer: Unmanaged<DisplayLinkObserver>?

    func snapshot() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current else { return nil }
        return ["timestamp": c.timestamp, "frame": c.frame, "refreshRate": c.refreshRate]
    }

    /// Called from the CV thread. Bumps the frame counter, updates the
    /// snapshot under the lock, then hops to main to notify subscribers.
    func acceptFrame(timestamp: Double, refreshRate: Double) {
        lock.lock()
        frameCounter += 1
        current = (timestamp: timestamp, frame: frameCounter, refreshRate: refreshRate)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.fire() }
    }

    override func install() -> Token? {
        var newLink: CVDisplayLink?
        let createStatus = CVDisplayLinkCreateWithActiveCGDisplays(&newLink)
        guard createStatus == kCVReturnSuccess, let link = newLink else { return nil }

        let retained = Unmanaged.passRetained(self)
        self.refconRetainer = retained
        let refcon = retained.toOpaque()

        let cbStatus = CVDisplayLinkSetOutputCallback(link, displayLinkCallback, refcon)
        guard cbStatus == kCVReturnSuccess else {
            retained.release()
            self.refconRetainer = nil
            return nil
        }

        let startStatus = CVDisplayLinkStart(link)
        guard startStatus == kCVReturnSuccess else {
            _ = CVDisplayLinkSetOutputCallback(link, nil, nil)
            retained.release()
            self.refconRetainer = nil
            return nil
        }

        self.link = link

        return Token { [weak self] in self?.teardown() }
    }

    private func teardown() {
        if let link = link {
            // Order matters: Stop first to halt the callback queue, then clear
            // the callback so any in-flight invocation can't reach our refcon
            // after we release it. Swift ARC releases the CVDisplayLink ref
            // when `self.link` is nilled out.
            if CVDisplayLinkIsRunning(link) { _ = CVDisplayLinkStop(link) }
            _ = CVDisplayLinkSetOutputCallback(link, nil, nil)
        }
        link = nil

        if let retainer = refconRetainer {
            retainer.release()
            refconRetainer = nil
        }

        lock.lock()
        current = nil
        frameCounter = 0
        lock.unlock()
    }
}

// MARK: - DisplaySnapshot
//
// Single-frame screen capture via ScreenCaptureKit. SCStream is the API Apple
// has been pushing since macOS 12.3; CGDisplayCreateImage is deprecated on
// 14 and routes through the same compositor anyway. SCScreenshotManager
// (14+) gives us a one-shot capture with no stream-lifecycle bookkeeping.
//
// macOS 13 fallback uses CGWindowListCreateImage with the .optionAll filter
// (CGDisplayCreateImage's spiritual replacement — the public migration path
// Apple suggests in 14's deprecation notice). README says macOS 14+ for
// install but the build target is 13.0; both branches stay in for now.
//
// Region capture clips after-the-fact rather than driving SCContentFilter's
// rect mode — the latter requires reasoning about display-pixel vs point
// coordinates per-display, and JS-side callers (CloudPad, DigUp) want point-
// space rects.

enum DisplaySnapshot {
    struct Options {
        var displayID: CGDirectDisplayID
        var region: CGRect?
        var format: String         // "png" | "jpeg"
        var quality: Double        // 0..1, jpeg only
    }

    /// Returns a dataURL + native pixel size, or nil on failure. The dataURL
    /// is directly droppable into <img src> from JS.
    static func capture(_ opts: Options, completion: @escaping ([String: Any]?) -> Void) {
        if #available(macOS 14.0, *) {
            captureWithSCKit(opts, completion: completion)
        } else {
            captureLegacy(opts, completion: completion)
        }
    }

    @available(macOS 14.0, *)
    private static func captureWithSCKit(_ opts: Options, completion: @escaping ([String: Any]?) -> Void) {
        SCShareableContent.getWithCompletionHandler { content, _ in
            guard let content = content,
                  let display = content.displays.first(where: { $0.displayID == opts.displayID })
                                ?? content.displays.first else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // SCStreamConfiguration measures in pixels; SCDisplay.{width,height}
            // are the pixel resolution of the display surface SC composes.
            config.width  = display.width
            config.height = display.height
            config.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { cgImage, _ in
                guard let cgImage = cgImage else {
                    DispatchQueue.main.async { completion(nil) }; return
                }
                let final = applyRegion(cgImage, region: opts.region, display: display)
                let payload = encodeAsDataURL(final, format: opts.format, quality: opts.quality)
                DispatchQueue.main.async { completion(payload) }
            }
        }
    }

    private static func captureLegacy(_ opts: Options, completion: @escaping ([String: Any]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let bounds = CGDisplayBounds(opts.displayID)
            // CGWindowListCreateImage on 13 is the public successor to
            // CGDisplayCreateImage; it routes through the same compositor.
            guard let cgImage = CGWindowListCreateImage(
                bounds,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution]
            ) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let final = applyRegionLegacy(cgImage, region: opts.region, displayBounds: bounds)
            let payload = encodeAsDataURL(final, format: opts.format, quality: opts.quality)
            DispatchQueue.main.async { completion(payload) }
        }
    }

    @available(macOS 14.0, *)
    private static func applyRegion(_ image: CGImage, region: CGRect?, display: SCDisplay) -> CGImage {
        guard let region = region else { return image }
        let scaleX = CGFloat(image.width)  / CGFloat(display.frame.width)
        let scaleY = CGFloat(image.height) / CGFloat(display.frame.height)
        let pixelRect = CGRect(
            x: region.origin.x * scaleX,
            y: region.origin.y * scaleY,
            width:  region.size.width  * scaleX,
            height: region.size.height * scaleY
        ).integral
        guard let cropped = image.cropping(to: pixelRect) else { return image }
        return cropped
    }

    private static func applyRegionLegacy(_ image: CGImage, region: CGRect?, displayBounds: CGRect) -> CGImage {
        guard let region = region else { return image }
        let scaleX = CGFloat(image.width)  / displayBounds.width
        let scaleY = CGFloat(image.height) / displayBounds.height
        let pixelRect = CGRect(
            x: region.origin.x * scaleX,
            y: region.origin.y * scaleY,
            width:  region.size.width  * scaleX,
            height: region.size.height * scaleY
        ).integral
        guard let cropped = image.cropping(to: pixelRect) else { return image }
        return cropped
    }

    private static func encodeAsDataURL(_ image: CGImage, format: String, quality: Double) -> [String: Any]? {
        let isJPEG = format.lowercased() == "jpeg" || format.lowercased() == "jpg"
        let utType: CFString = isJPEG ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString
        let mime = isJPEG ? "image/jpeg" : "image/png"
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable as CFMutableData, utType, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if isJPEG {
            props[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, quality))
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let base64 = (mutable as Data).base64EncodedString()
        return [
            "dataURL": "data:\(mime);base64,\(base64)",
            "width":   image.width,
            "height":  image.height
        ]
    }
}

// MARK: - Appearance

enum Appearance {
    static func current() -> [String: Any] {
        var isDark = false
        if let app = NSApp {
            isDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let r = Int(((accent?.redComponent   ?? 0) * 255).rounded())
        let g = Int(((accent?.greenComponent ?? 0) * 255).rounded())
        let b = Int(((accent?.blueComponent  ?? 0) * 255).rounded())
        return [
            "dark":         isDark,
            "accent":       ["r": r, "g": g, "b": b],
            "accentHex":    String(format: "#%02x%02x%02x", r, g, b),
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ]
    }
}

/// Light/dark + accent + reduce-motion. Push on:
///   - AppleInterfaceThemeChangedNotification (distributed) — dark/light flip
///   - NSWorkspace.accessibilityDisplayOptionsDidChangeNotification — reduce motion
///   - 2s poll — accent color (no notification exists for NSColor.controlAccentColor)
final class AppearanceObserver: RefCountedObserver {
    static let shared = AppearanceObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let ncToken = installNotifications([
            (DistributedNotificationCenter.default(),
             NSNotification.Name("AppleInterfaceThemeChangedNotification")),
            (NSWorkspace.shared.notificationCenter,
             NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        ])

        // Accent color has no system notification; poll while observer is
        // active. The whole timer stops once the last subscriber leaves.
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
