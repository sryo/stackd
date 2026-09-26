import Foundation
import CoreGraphics
import ImageIO

// Tests for `Sources/DataSources/Thumbnails.swift`.
//
// The public surface is the single async `generate(...)` entry point; the
// representation/format helpers behind it are private. Completion is always
// delivered on main, so tests spin the main run loop with a deadline.
//
// Covered:
//   - Missing-file bail (absolute, empty, and tilde paths) → completion(nil),
//     queued on main rather than fired inline.
//   - Success path on a temp PNG rendered by QuickLook, encoded as jpeg.
//
// Not covered: the timeout watchdog (needs a file QuickLook hangs on).

private func thumbSpin(timeout: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func registerThumbnailsTests() {
    test("generate on a missing path completes with nil, asynchronously on main") {
        let missing = [
            "/var/empty/definitely-not-a-real-file-\(UUID().uuidString).bin",
            "",
            "~/.stackd-thumbnails-test-\(UUID().uuidString)-missing.bin"
        ]
        for path in missing {
            var calls = 0
            var result: [String: Any]?
            var onMain = false
            Thumbnails.generate(
                path: path,
                size: CGSize(width: 128, height: 128),
                scale: 2.0,
                representation: "all",
                format: "png",
                quality: 0.85,
                timeoutSeconds: 5.0
            ) { r in
                calls += 1
                result = r
                onMain = Thread.isMainThread
            }
            try expectEqual(calls, 0, "completion for '\(path)' must be queued on main, not fired inline")
            thumbSpin(timeout: 2) { calls > 0 }
            try expectEqual(calls, 1, "completion for '\(path)' should fire exactly once")
            try expect(result == nil, "missing file '\(path)' should yield nil")
            try expect(onMain, "completion must be delivered on main")
        }
    }

    test("generate renders a real image file into a jpeg dataURL") {
        let path = NSTemporaryDirectory() + "stackd-thumbnails-test-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                  bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Expectation(message: "failed to build CGContext")
        }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         "public.png" as CFString, 1, nil) else {
            throw Expectation(message: "failed to build source PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        try expect(CGImageDestinationFinalize(dest), "failed to write source PNG")

        var done = false
        var result: [String: Any]?
        Thumbnails.generate(
            path: path,
            size: CGSize(width: 64, height: 64),
            scale: 1.0,
            representation: "all",
            format: "jpeg",
            quality: 0.85,
            timeoutSeconds: 5.0
        ) { r in
            result = r
            done = true
        }
        thumbSpin(timeout: 6) { done }
        guard let r = result else {
            throw Expectation(message: "QuickLook returned no thumbnail for a plain PNG")
        }
        let url = r["dataURL"] as? String ?? ""
        try expect(url.hasPrefix("data:image/jpeg;base64,"), "expected a jpeg dataURL, got: \(url.prefix(32))")
        try expect((r["width"] as? Int ?? 0) > 0, "width should be positive")
        try expect((r["height"] as? Int ?? 0) > 0, "height should be positive")
        let type = r["type"] as? String ?? ""
        try expect(["icon", "lowQualityThumbnail", "thumbnail"].contains(type),
                   "unexpected representation type '\(type)'")
    }
}
