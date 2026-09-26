import Foundation
import CoreGraphics
import AppKit

// Tests for `Sources/DataSources/Vision.swift`.
//
// Every public request entry point funnels through a private `runRequest`
// that decodes the input image, runs VNImageRequestHandler on a global
// queue, and completes on main. Running real Vision requests is expensive
// and model-dependent, so the tests cover:
//   1. `Vision.decodeImage(_:)` — the gatekeeper for every request: dataURL
//      strings and filesystem paths → CGImage, everything else → nil.
//   2. `Vision.featurePrintDistance(a:b:)` — synchronous; its rejection
//      paths (nil, non-base64, non-archive) need no Vision run.
//   3. The request entry points' undecodable-input bail: completion(nil),
//      delivered asynchronously on main.
//
// Not covered: request results (bounding-box y-flip, OCR level mapping,
// joint names) — private decode closures reachable only through a real
// VNImageRequestHandler run.

private func visionSpin(timeout: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

/// 4x4 opaque red PNG, encoded in memory.
private func visionTestPNG() -> Data? {
    guard let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                              bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    guard let image = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}

func registerVisionTests() {
    // ── decodeImage: rejection paths ───────────────────────────────────────
    test("decodeImage returns nil for nil source") {
        // Bridge.swift hands `body["image"]` straight through — JS may omit
        // the key, in which case source is nil. Must not crash.
        try expect(Vision.decodeImage(nil) == nil)
    }

    test("decodeImage returns nil for a non-string source") {
        // JS could hand an Int, Dict, or Array. The function only accepts
        // String; everything else falls through to nil.
        try expect(Vision.decodeImage(42) == nil)
        try expect(Vision.decodeImage([1, 2, 3]) == nil)
        try expect(Vision.decodeImage(["x": 1]) == nil)
    }

    test("decodeImage returns nil for an empty string") {
        // Empty string is neither a data: URL nor a readable path.
        try expect(Vision.decodeImage("") == nil)
    }

    test("decodeImage returns nil for a non-existent filesystem path") {
        // NSImage(contentsOfFile:) returns nil for missing files — the
        // function must surface that as a nil CGImage, not crash.
        let bogus = "/var/empty/definitely-not-a-real-image-\(UUID().uuidString).png"
        try expect(Vision.decodeImage(bogus) == nil)
    }

    test("decodeImage returns nil for a malformed data: URL") {
        // The decoder splits at the first comma and base64-decodes the
        // payload. A data: URL with no comma, or a comma followed by
        // non-base64 garbage, must surface as nil.
        try expect(Vision.decodeImage("data:image/png;base64") == nil) // no comma
        try expect(Vision.decodeImage("data:image/png;base64,!!!not-base64!!!") == nil)
    }

    test("decodeImage returns nil for a data: URL whose base64 payload isn't a valid image") {
        // Base64 decodes successfully but CGImageSource can't sniff a known
        // image format from "hello world" bytes.
        let payload = Data("hello world".utf8).base64EncodedString()
        try expect(Vision.decodeImage("data:image/png;base64,\(payload)") == nil)
    }

    // ── decodeImage: success paths ─────────────────────────────────────────
    test("decodeImage round-trips a valid PNG data: URL into a CGImage") {
        guard let png = visionTestPNG() else {
            throw Expectation(message: "failed to build source PNG")
        }
        guard let decoded = Vision.decodeImage("data:image/png;base64,\(png.base64EncodedString())") else {
            throw Expectation(message: "decodeImage returned nil for a valid PNG dataURL")
        }
        try expectEqual(decoded.width, 4)
        try expectEqual(decoded.height, 4)
    }

    test("decodeImage reads an image from a filesystem path") {
        guard let png = visionTestPNG() else {
            throw Expectation(message: "failed to build source PNG")
        }
        let path = NSTemporaryDirectory() + "stackd-vision-test-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try png.write(to: URL(fileURLWithPath: path))
        guard let decoded = Vision.decodeImage(path) else {
            throw Expectation(message: "decodeImage returned nil for a PNG on disk")
        }
        try expect(decoded.width > 0 && decoded.height > 0, "decoded image should have positive size")
    }

    // ── featurePrintDistance: rejection paths ──────────────────────────────
    test("featurePrintDistance returns nil when either argument is nil") {
        // JS may omit one or both blobs. Both nil arms must short-circuit.
        try expect(Vision.featurePrintDistance(a: nil, b: nil) == nil)
        try expect(Vision.featurePrintDistance(a: "AAAA", b: nil) == nil)
        try expect(Vision.featurePrintDistance(a: nil, b: "AAAA") == nil)
    }

    test("featurePrintDistance returns nil for non-base64 strings") {
        // Data(base64Encoded:) returns nil for non-base64 — caller path
        // must surface as nil result, not throw.
        try expect(Vision.featurePrintDistance(a: "!!!", b: "!!!") == nil)
    }

    test("featurePrintDistance returns nil for base64 that isn't a valid archive") {
        // Base64 decodes successfully but NSKeyedUnarchiver rejects the
        // bytes — the do/catch must collapse to nil, not propagate.
        let junk = Data("not an archive".utf8).base64EncodedString()
        try expect(Vision.featurePrintDistance(a: junk, b: junk) == nil)
    }

    // ── request entry points: bail on undecodable input ───────────────────
    test("request entry points complete with nil on undecodable input, asynchronously on main") {
        // Each call passes an input decodeImage rejects: a missing path,
        // nil, a malformed data: URL, a non-string. Completion must be
        // queued on main (never inline — Bridge's respond path assumes it)
        // and carry nil.
        var results: [String: [String: Any]?] = [:]
        var offMain: [String] = []
        func record(_ name: String) -> ([String: Any]?) -> Void {
            return { r in
                if !Thread.isMainThread { offMain.append(name) }
                results[name] = .some(r)
            }
        }
        Vision.ocr(image: "/var/empty/missing-\(UUID().uuidString).png",
                   languages: ["en-US"], level: "accurate", completion: record("ocr"))
        Vision.faces(image: nil, completion: record("faces"))
        Vision.featurePrint(image: "data:image/png;base64,not-base64", completion: record("featurePrint"))
        Vision.subjectMask(image: ["not": "an image"], completion: record("subjectMask"))
        Vision.bodyPose(image: 12345, completion: record("bodyPose"))
        try expect(results.isEmpty, "completions fired inline: \(results.keys.sorted())")
        visionSpin(timeout: 2) { results.count == 5 }
        try expectEqual(results.keys.sorted(), ["bodyPose", "faces", "featurePrint", "ocr", "subjectMask"])
        for (name, r) in results {
            try expect(r == nil, "\(name) should complete with nil")
        }
        try expectEqual(offMain, [], "completions delivered off main")
    }
}
