import Foundation
import AppKit
import CoreImage
import CoreVideo
import ImageIO

// Tests for ImageEncoding.swift — the single image → data: URL path behind
// thumbnails, display snapshots, camera frames, Vision masks, app icons and
// symbols. The PNG golden below is the exact output of the per-site encoders
// this helper replaced (CGImageDestination, no properties), so a drift in the
// shared recipe — or a caller that stops routing through it — shows up as a
// byte difference. JPEG output depends on the system encoder, so it is
// compared against the same recipe run inline instead of a frozen literal.

/// 2x2 opaque sRGB image: red, green / blue, white.
private func fixtureImage() -> CGImage {
    let pixels: [UInt8] = [
        255, 0, 0, 255,    0, 255, 0, 255,
        0, 0, 255, 255,    255, 255, 255, 255,
    ]
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private let goldenPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAADtGLyqAAAAFElEQVQIHWP4z8DwHwRZGME0AwMAPv8GAHhtEIAAAAAASUVORK5CYII="

/// The recipe every call site used before it shared ImageEncoding.
private func legacyEncode(_ image: CGImage, uti: String, quality: Double?) -> String? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, uti as CFString, 1, nil) else { return nil }
    var props: [CFString: Any] = [:]
    if let q = quality { props[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, q)) }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return (data as Data).base64EncodedString()
}

private func payloadBytes(_ dataURL: String) -> Data? {
    guard let comma = dataURL.firstIndex(of: ",") else { return nil }
    return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
}

private func bgraPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
          let buffer = buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * height)
    }
    return buffer
}

func registerImageEncodingTests() {
    test("ImageEncoding: PNG data URL matches the golden bytes of the encoders it replaced") {
        let url = ImageEncoding.dataURL(fixtureImage(), format: .png, quality: 0.85)
        try expectEqual(url, "data:image/png;base64," + goldenPNGBase64)
    }

    test("ImageEncoding: PNG ignores quality") {
        let low  = ImageEncoding.dataURL(fixtureImage(), format: .png, quality: 0.1)
        let high = ImageEncoding.dataURL(fixtureImage(), format: .png, quality: 1)
        try expectEqual(low, high)
    }

    test("ImageEncoding: JPEG matches the inline recipe and clamps quality to 0...1") {
        let image = fixtureImage()
        for q in [0.5, 0.85, 7.0, -3.0] {
            let url = ImageEncoding.dataURL(image, format: .jpeg, quality: q)
            let expected = legacyEncode(image, uti: "public.jpeg", quality: q).map { "data:image/jpeg;base64," + $0 }
            try expectEqual(url, expected, "quality \(q)")
        }
        try expectEqual(ImageEncoding.dataURL(image, format: .jpeg, quality: 7),
                        ImageEncoding.dataURL(image, format: .jpeg, quality: 1))
        try expectEqual(ImageEncoding.dataURL(image, format: .jpeg, quality: -3),
                        ImageEncoding.dataURL(image, format: .jpeg, quality: 0))
    }

    test("ImageEncoding: payload is exactly dataURL + pixel width/height") {
        guard let payload = ImageEncoding.payload(fixtureImage(), format: .png, quality: 0.85) else {
            throw Expectation(message: "payload returned nil")
        }
        try expectEqual(Set(payload.keys), Set(["dataURL", "width", "height"]))
        try expectEqual(payload["width"] as? Int, 2)
        try expectEqual(payload["height"] as? Int, 2)
        try expectEqual(payload["dataURL"] as? String, "data:image/png;base64," + goldenPNGBase64)
    }

    test("ImageEncoding: pixel buffers convert through CoreImage with their own dimensions") {
        guard let buffer = bgraPixelBuffer(width: 3, height: 2),
              let image = ImageEncoding.cgImage(from: buffer) else {
            throw Expectation(message: "pixel buffer did not convert")
        }
        try expectEqual(image.width, 3)
        try expectEqual(image.height, 2)

        guard let payload = ImageEncoding.payload(pixelBuffer: buffer, format: .jpeg, quality: 0.5) else {
            throw Expectation(message: "pixel-buffer payload returned nil")
        }
        try expect((payload["dataURL"] as? String ?? "").hasPrefix("data:image/jpeg;base64,"))
        try expectEqual(payload["width"] as? Int, 3)
        try expectEqual(payload["height"] as? Int, 2)
    }

    test("ImageEncoding: every pixel-buffer conversion shares one CIContext") {
        try expect(ImageEncoding.ciContext === ImageEncoding.ciContext, "ciContext must be a single shared instance")
    }

    test("ImageEncoding: drawn NSImage rasterizes to a PNG data URL") {
        let url = ImageEncoding.pngDataURL(size: NSSize(width: 4, height: 4)) {
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        }
        guard let url = url, let bytes = payloadBytes(url) else {
            throw Expectation(message: "drawn image did not encode")
        }
        try expect(url.hasPrefix("data:image/png;base64,"))
        try expectEqual(Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    test("ImageEncoding: Format carries the mime type the data URL header uses") {
        try expectEqual(ImageEncoding.Format.png.mime, "image/png")
        try expectEqual(ImageEncoding.Format.jpeg.mime, "image/jpeg")
    }
}
