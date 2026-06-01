import AppKit
import CoreGraphics
import Foundation

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
        guard let capture = SkyLightWindowCapture.captureWindowList else { return nil }

        var wid = UInt32(windowID)
        let options: UInt32 = (1 << 11) | (1 << 9)
        guard let cfArr = capture(SkyLight.cid, &wid, 1, options)?.takeRetainedValue() else {
            return nil
        }
        let arr = cfArr as NSArray
        guard arr.count > 0 else { return nil }
        let cgImage = arr[0] as! CGImage

        return encode(image: cgImage, format: format, quality: quality)
    }

    /// CGImage → dataURL via CGImageDestination. Mirrors the encode path
    /// in CameraCapture.swift / VisionSubjectMask.swift — same UTI map,
    /// same base64 → "data:<mime>;base64,…" wrapping.
    private static func encode(image: CGImage,
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
