import AppKit
import CoreImage
import CoreVideo
import ImageIO

/// The one path from pixels to `data:` URLs, shared by thumbnails, display
/// snapshots, camera frames, Vision masks, app icons and symbols. Payloads
/// are the `{ dataURL, width, height }` shape stacks drop straight into
/// `<img src>`.
enum ImageEncoding {
    enum Format {
        case png, jpeg

        var utType: CFString {
            switch self {
            case .png:  return "public.png" as CFString
            case .jpeg: return "public.jpeg" as CFString
            }
        }

        var mime: String {
            switch self {
            case .png:  return "image/png"
            case .jpeg: return "image/jpeg"
            }
        }
    }

    /// One CoreImage context for every pixel-buffer conversion. Constructing
    /// a context allocates GPU state, so per-frame construction dominates the
    /// cost of a camera stream; CIContext is safe to use from any queue.
    static let ciContext = CIContext()

    /// Encoded image bytes. `quality` (clamped to 0...1) applies to JPEG only.
    static func data(_ image: CGImage, format: Format, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, format.utType, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, quality))
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func dataURL(_ image: CGImage, format: Format, quality: Double) -> String? {
        guard let bytes = data(image, format: format, quality: quality) else { return nil }
        return "data:\(format.mime);base64,\(bytes.base64EncodedString())"
    }

    /// `{ dataURL, width, height }` with the image's pixel dimensions.
    static func payload(_ image: CGImage, format: Format, quality: Double) -> [String: Any]? {
        guard let url = dataURL(image, format: format, quality: quality) else { return nil }
        return ["dataURL": url, "width": image.width, "height": image.height]
    }

    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    static func payload(pixelBuffer: CVPixelBuffer, format: Format, quality: Double) -> [String: Any]? {
        guard let image = cgImage(from: pixelBuffer) else { return nil }
        return payload(image, format: format, quality: quality)
    }

    /// Rasterizes whatever `draw` paints into a `size`-point image (drawing
    /// origin at the bottom-left, as with any focused NSImage) and returns it
    /// as a PNG data URL. The bitmap scale follows the main screen.
    static func pngDataURL(size: NSSize, draw: () -> Void) -> String? {
        let target = NSImage(size: size)
        target.lockFocus()
        draw()
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
