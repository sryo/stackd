import AppKit
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

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
