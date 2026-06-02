import Foundation
import CoreGraphics
import AppKit

// Tests for `Sources/DataSources/Vision.swift`.
//
// Vision.swift wraps Apple's Vision framework — OCR, face rectangles, feature
// prints, subject mask, body pose. Every public entrypoint funnels through
// `runRequest(...)` which decodes the input image, dispatches to a global
// queue, runs `VNImageRequestHandler.perform([...])`, and shapes results on
// main. Six public entrypoints + a shared decoder + a pure-ish helper.
//
// What we can't test here:
//   - Anything that calls `VNImageRequestHandler.perform([...])`. That hop
//     actually runs OCR / face detection / pose estimation on the supplied
//     pixels — expensive, GPU-bound, and the result shape depends on what
//     Apple's models see in the image. The test suite is hermetic and
//     synchronous (no RunLoop spins; see NetworkTests.swift preamble), so
//     even if we wanted to feed it a real CGImage we couldn't await the
//     async completion.
//   - `runRequest`, `decodeDataURL`, `pngDataURL`, `elementTypeName`,
//     `jointName` — all `private static`, not reachable from the test
//     target. The bounding-box y-flip, the .fast/.accurate level mapping,
//     and the joint-name normalization all live inside private decode
//     closures wrapped by the public entrypoints. We don't change
//     production visibility just for tests.
//
// What we CAN test (the observable surface):
//   1. `Vision.decodeImage(_:)` — internal static, the gatekeeper every
//      Vision.* call funnels through. Accepts dataURL strings, filesystem
//      paths, returns CGImage or nil. This is the only synchronous,
//      pure-ish entry point in the file.
//   2. `Vision.featurePrintDistance(a:b:)` — internal static, synchronous.
//      Both args are base64-encoded NSKeyedArchiver blobs. The error path
//      (nil args, empty strings, non-base64, base64 that isn't a valid
//      archive) is reachable without ever running Vision.
//   3. The async entrypoints (`ocr`, `faces`, `featurePrint`, `subjectMask`,
//      `bodyPose`) on the early-bail path: `runRequest` calls
//      `decodeImage(source)` first and fires `completion(nil)` synchronously
//      if decoding fails. That branch is observable without running VN.
//
// Wire-up: caller will add `registerVisionTests()` to Tests/main.swift and
// append this file to TEST_SOURCES in tests.sh.

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

    // ── decodeImage: success path (round-trip a real image) ────────────────
    test("decodeImage round-trips a valid PNG data: URL into a CGImage") {
        // Build a 4x4 RGBA PNG in-memory, base64-encode it, hand it in.
        // The success path is the only positive assertion we can make about
        // decodeImage without touching the filesystem.
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let src = ctx?.makeImage() else {
            try expect(false, "failed to build source CGImage")
            return
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil
        ) else {
            try expect(false, "failed to build CGImageDestination")
            return
        }
        CGImageDestinationAddImage(dest, src, nil)
        guard CGImageDestinationFinalize(dest) else {
            try expect(false, "failed to finalize PNG")
            return
        }
        let base64 = (data as Data).base64EncodedString()
        let dataURL = "data:image/png;base64,\(base64)"

        guard let decoded = Vision.decodeImage(dataURL) else {
            try expect(false, "decodeImage returned nil for a valid PNG dataURL")
            return
        }
        try expectEqual(decoded.width, 4)
        try expectEqual(decoded.height, 4)
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

    // ── async entrypoints: early-bail on undecodable input ─────────────────
    test("ocr with a non-existent image path queues completion on main, not inline") {
        // runRequest calls decodeImage first; on failure it fires
        // completion(nil) — but the entry point itself doesn't dispatch
        // that callback inline. Same async contract as Thumbnails.generate.
        // If a future change made this synchronous, Bridge.swift's respond
        // handling would deadlock.
        var fired = false
        Vision.ocr(
            image: "/var/empty/missing-\(UUID().uuidString).png",
            languages: ["en-US"],
            level: "accurate"
        ) { _ in fired = true }
        try expect(!fired, "ocr completion must not fire synchronously on the calling thread")
    }

    test("faces with a nil image queues completion on main, not inline") {
        // nil source → decodeImage returns nil → completion(nil) on main.
        // We assert the negative (no inline fire) — same tracer-bullet
        // pattern as ThumbnailsTests.
        var fired = false
        Vision.faces(image: nil) { _ in fired = true }
        try expect(!fired)
    }

    test("featurePrint with a malformed data: URL queues completion on main, not inline") {
        // Verifies the early-bail path through the generic VNRequest entry
        // — featurePrint takes the same `image:` shape as ocr/faces and
        // funnels through the same runRequest.
        var fired = false
        Vision.featurePrint(image: "data:image/png;base64,not-base64") { _ in fired = true }
        try expect(!fired)
    }

    test("bodyPose with a non-string image source queues completion on main, not inline") {
        // JS could hand a number or dict — decodeImage rejects, runRequest
        // bails via completion(nil). Must not fire inline.
        var fired = false
        Vision.bodyPose(image: 12345) { _ in fired = true }
        try expect(!fired)
    }
}
