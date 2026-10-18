import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// =====================================================================
// MARK: - Per-window snapshot via SkyLight
// =====================================================================

// Per-window snapshot via SkyLight private SPI. Synchronous, no TCC prompt,
// and works for windows that are offscreen / minimized / on another space —
// the trick AltTab uses to render its live window-switcher grid.
//
// Distinct from Sources/DataSources/DisplaySnapshot.swift (which uses
// public ScreenCaptureKit for display capture): SCK can't grab a window
// the user hasn't currently exposed, and it triggers the Screen Recording
// TCC prompt. CGSHWCaptureWindowList has neither limitation but lives on
// private SkyLight; if the symbol vanishes in a future macOS, callers see
// nil and degrade.
//
// Stream / video variant is a separate ship — this is one-shot only.

private enum SkyLightWindowCapture {
    // CGSHWCaptureWindowList(cid, wids, count, options) → CFArrayRef of
    // CGImageRefs, one per requested window ID. options is a flag set;
    // (1 << 9) = nominal resolution (1x point size, no Retina upsample);
    // (1 << 11) = ignore the window's global clip shape (capture full
    // rectangular content, not just the visible region). Yabai and
    // JankyBorders both use the (nominal | ignore-clip) combo for the
    // sharpest, most predictable result.
    typealias HWCaptureWindowListFn = @convention(c) (
        Int32, UnsafePointer<UInt32>, Int32, UInt32
    ) -> Unmanaged<CFArray>?

    static let captureWindowList: HWCaptureWindowListFn? =
        SkyLight.sym("CGSHWCaptureWindowList")
}

extension WindowsByID {
    /// Snapshot a single window's current contents. `format` is "png"
    /// (default, lossless, larger payload) or "jpeg" (smaller, lossy).
    /// `quality` 0..1 applies to jpeg only — the canonical default lives in
    /// `Runtime/api.js` (`sd.windows.snapshot`), so this signature takes
    /// quality as-is. Returns
    ///   { dataURL, width, height }
    /// or nil if the SPI symbol resolves missing, the window id is invalid,
    /// or the encode fails. Works for hidden / minimized / off-space
    /// windows — the private SkyLight path doesn't gate on visibility.
    static func snapshot(windowID: CGWindowID,
                         format: String = "png",
                         quality: Double?) -> [String: Any]? {
        guard let cgImage = captureImage(windowID: windowID) else { return nil }
        return encode(image: cgImage, format: format, quality: quality)
    }

    /// One CGSHWCaptureWindowList grab at nominal (1x) resolution, clip
    /// shape ignored. nil when the SPI is missing or the id is invalid.
    fileprivate static func captureImage(windowID: CGWindowID) -> CGImage? {
        guard let capture = SkyLightWindowCapture.captureWindowList else { return nil }
        var wid = UInt32(windowID)
        let options: UInt32 = (1 << 11) | (1 << 9)
        guard let cfArr = capture(SkyLight.cid, &wid, 1, options)?.takeRetainedValue() else {
            return nil
        }
        let arr = cfArr as NSArray
        guard arr.count > 0 else { return nil }
        return (arr[0] as! CGImage)
    }

    /// CGImage → dataURL via CGImageDestination. Mirrors the encode path
    /// in CameraCapture.swift / VisionSubjectMask.swift — same UTI map,
    /// same base64 → "data:<mime>;base64,…" wrapping.
    fileprivate static func encode(image: CGImage,
                               format: String,
                               quality: Double?) -> [String: Any]? {
        let isPNG = (format == "png")
        let utType = (isPNG ? "public.png" : "public.jpeg") as CFString
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, utType, 1, nil
        ) else { return nil }
        // PNG ignores the quality dict; for JPEG, fall back to a baseline if
        // the caller (api.js) omits the field — but the canonical default is
        // declared in `sd.windows.snapshot` so this rarely fires.
        let props: [CFString: Any] = isPNG ? [:] : [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality ?? 0.85))
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let base64 = (data as Data).base64EncodedString()
        let mime = isPNG ? "image/png" : "image/jpeg"
        return [
            "dataURL": "data:\(mime);base64,\(base64)",
            "width":   image.width,
            "height":  image.height
        ]
    }
}

/// Live window thumbnail: re-captures one window at a fixed rate and emits
/// each changed frame as a downscaled dataURL. Backs `sd.windows.stream`.
///
/// Timer-driven by necessity: the window server has no public or SkyLight
/// notification for "this window's backing store changed", so there is no
/// event to wait on. Unchanged frames are dropped here (byte-identical
/// encode), so a static window costs a capture + encode per tick but no
/// bridge traffic.
final class WindowStream {
    /// Default 10fps; 30fps ceiling keeps a few simultaneous streams well
    /// under a core (each tick is a full-window capture + scale + encode).
    static func clampedFps(_ raw: Double?) -> Double {
        let f = raw ?? 10
        if f <= 0 { return 10 }
        return min(f, 30)
    }

    /// Aspect-preserving fit to `maxWidth`. Never upscales.
    static func scaledSize(width: Int, height: Int, maxWidth: Int?) -> (width: Int, height: Int) {
        guard let maxWidth = maxWidth, maxWidth > 0, width > maxWidth else { return (width, height) }
        let h = Int((Double(height) * Double(maxWidth) / Double(width)).rounded())
        return (maxWidth, max(1, h))
    }

    private let fps: Double
    private let maxWidth: Int?
    private let quality: Double
    private let capture: () -> CGImage?
    private let emit: ([String: Any]) -> Void
    private let queue = DispatchQueue(label: "stackd.windows.stream", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var lastDataURL: String?

    init(fps: Double, maxWidth: Int?, quality: Double,
         capture: @escaping () -> CGImage?,
         emit: @escaping ([String: Any]) -> Void) {
        self.fps = fps
        self.maxWidth = maxWidth
        self.quality = quality
        self.capture = capture
        self.emit = emit
    }

    /// A stream of a real window via CGSHWCaptureWindowList, which keeps
    /// working while the window is minimized, hidden or on another space.
    static func forWindow(_ windowID: CGWindowID, fps: Double, maxWidth: Int?, quality: Double,
                          emit: @escaping ([String: Any]) -> Void) -> WindowStream {
        WindowStream(fps: fps, maxWidth: maxWidth, quality: quality,
                     capture: { WindowsByID.captureImage(windowID: windowID) },
                     emit: emit)
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil, !stopped else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / fps
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        lock.lock()
        stopped = true
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    /// One capture → scale → encode → emit-if-changed step.
    func tick() {
        lock.lock(); let isStopped = stopped; lock.unlock()
        if isStopped { return }
        guard let frame = autoreleasepool(invoking: { encodeFrame() }) else { return }
        let url = frame["dataURL"] as? String
        lock.lock()
        let changed = !stopped && url != lastDataURL
        if changed { lastDataURL = url }
        lock.unlock()
        if changed { emit(frame) }
    }

    private func encodeFrame() -> [String: Any]? {
        guard let image = capture() else { return nil }
        let size = Self.scaledSize(width: image.width, height: image.height, maxWidth: maxWidth)
        var scaled = image
        if size.width != image.width {
            // The capture's own color space and an opaque BGRA layout: no
            // color matching on draw and no un-premultiply on JPEG encode.
            // Medium interpolation is indistinguishable at thumbnail size and
            // a fraction of .high's resample cost.
            let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: nil, width: size.width, height: size.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: bitmapInfo) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            guard let out = ctx.makeImage() else { return nil }
            scaled = out
        }
        return WindowsByID.encode(image: scaled, format: "jpeg", quality: quality)
    }
}
