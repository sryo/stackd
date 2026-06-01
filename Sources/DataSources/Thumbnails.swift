import Foundation
import AppKit
import QuickLookThumbnailing

// Thumbnails for arbitrary file paths via QLThumbnailGenerator. Public API,
// no TCC — Quick Look reads whatever the user's process can already read,
// so file accessibility is the only gate. Generated representations are the
// same ones Finder, Mail, and Quick Look itself use, so we get rich
// previews for free (PDF first page, video poster, audio waveform, source
// code with syntax highlighting, app icons, …).
//
// One-shot only. The streaming generateRepresentations variant (icon →
// low-quality → high-quality progressive yield) is a later add — most
// callers want one image and the streaming API needs Bridge handle
// tracking the one-shot doesn't.
//
// Daemon-vs-stack: WebViews can't reach QLThumbnailGenerator themselves;
// even file:// loads of a binary asset only work for already-decoded
// formats the WebView understands. PDFs, .key, .numbers, .mov posters,
// arbitrary app bundles — only QL renders these. Genuine primitive.

enum Thumbnails {
    /// Generate a thumbnail for the file at `path` and return
    /// `{ dataURL, width, height, type, sourceWidth, sourceHeight }`.
    /// Returns nil on missing file or unrenderable type.
    ///
    /// - `path`: absolute or `~/…` filesystem path.
    /// - `size`: requested width/height in *points*; final pixel dimensions
    ///   are `size * scale`. Defaults to 128×128 if unset.
    /// - `scale`: backing scale factor (1 / 2 / 3). Defaults to the main
    ///   display's backing scale so the result is retina-sharp on the
    ///   screen calling it.
    /// - `representation`: which QL pass to request — "all" (default; best
    ///   available), "thumbnail" (forced high-res rendering, slower for
    ///   unknown types), "icon" (file-type icon only), or
    ///   "lowQualityThumbnail" (fast lossy preview).
    /// - `format`: "png" (default, lossless, preserves transparency) or
    ///   "jpeg" (`quality` 0..1 controls compression; jpeg only).
    /// - `quality`: jpeg quality 0..1, default 0.85; ignored for png.
    /// - `timeoutSeconds`: hard cap on QL latency; default 5s. QL has been
    ///   observed to hang on certain malformed files — better to surface
    ///   null than to leak callbacks.
    static func generate(path: String,
                         size: CGSize,
                         scale: CGFloat,
                         representation: String,
                         format: String,
                         quality: Double,
                         timeoutSeconds: Double,
                         completion: @escaping ([String: Any]?) -> Void) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: representationType(representation)
        )
        // .iconMode would force the icon-only path; .all already includes
        // icon fallback, so leave it unset.

        // One-shot fire-and-forget — QL handles the callback on an
        // internal queue. Box the completion so the timeout watchdog and
        // the QL callback can each only fire it once.
        final class Once {
            var fired = false
            let cb: ([String: Any]?) -> Void
            init(_ cb: @escaping ([String: Any]?) -> Void) { self.cb = cb }
            func fire(_ value: [String: Any]?) {
                if fired { return }
                fired = true
                cb(value)
            }
        }
        let once = Once { result in
            DispatchQueue.main.async { completion(result) }
        }

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep = rep else {
                once.fire(nil)
                return
            }
            let cg = rep.cgImage
            once.fire(encode(cgImage: cg, format: format, quality: quality,
                             type: typeName(rep.type)))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            once.fire(nil)
        }
    }

    private static func representationType(_ name: String) -> QLThumbnailGenerator.Request.RepresentationTypes {
        switch name {
        case "thumbnail":           return .thumbnail
        case "icon":                return .icon
        case "lowQualityThumbnail": return .lowQualityThumbnail
        default:                    return .all
        }
    }

    private static func typeName(_ t: QLThumbnailRepresentation.RepresentationType) -> String {
        switch t {
        case .icon:                return "icon"
        case .lowQualityThumbnail: return "lowQualityThumbnail"
        case .thumbnail:           return "thumbnail"
        @unknown default:          return "unknown"
        }
    }

    /// CGImage → dataURL via CGImageDestination. Mirrors Vision.pngDataURL
    /// but lets jpeg through too — file previews are usually photos and
    /// pay for the size reduction.
    private static func encode(cgImage: CGImage,
                               format: String,
                               quality: Double,
                               type: String) -> [String: Any]? {
        let (utType, mime, props): (CFString, String, [CFString: Any]?)
        if format == "jpeg" || format == "jpg" {
            utType = "public.jpeg" as CFString
            mime   = "image/jpeg"
            props  = [kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))]
        } else {
            utType = "public.png" as CFString
            mime   = "image/png"
            props  = nil
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, utType, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let base64 = (data as Data).base64EncodedString()
        return [
            "dataURL":      "data:\(mime);base64,\(base64)",
            "width":        cgImage.width,
            "height":       cgImage.height,
            "type":         type
        ]
    }
}
