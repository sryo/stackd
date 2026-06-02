import Foundation
import CoreGraphics

// Tests for `Sources/DataSources/Thumbnails.swift`.
//
// Thumbnails.swift is almost entirely private static helpers wrapping a
// single async QLThumbnailGenerator one-shot:
//   - representationType(_:)  String → QL representation enum
//   - typeName(_:)            QL enum → String
//   - encode(cgImage:...)     CGImage → dataURL dict
//
// None of those helpers are visible to the test target, and we don't
// change production visibility just for tests. The public surface is the
// single async `generate(path:size:scale:representation:format:quality:
// timeoutSeconds:completion:)` entry point.
//
// What we can't test here:
//   - The QL render path itself. QLThumbnailGenerator.generateBestRepresentation
//     is async, queues onto an internal QL worker, and requires a real
//     readable file. The suite avoids RunLoop spins (see NetworkTests.swift
//     preamble), so we can't await its completion.
//   - representationType / typeName / encode — all `private static`, not
//     reachable from the test target.
//
// What we CAN test: the synchronous prelude of `generate()`. Before QL is
// touched, the function:
//   1. Expands the tilde in `path`.
//   2. Builds a file: URL.
//   3. Runs FileManager.default.fileExists at `expanded` and bails to
//      `completion(nil)` (queued on main) if the file is missing.
//
// That prelude is the bug surface most likely to regress (bad expansion,
// throw, fatalError on edge-case CGSize/scale). We hit it directly with
// definitely-missing paths and assert it returns synchronously, never
// throws, and never invokes the QL pipeline.
//
// The completion fires via DispatchQueue.main.async, which won't drain
// inside a synchronous test body — so we assert the negative: the
// completion did NOT fire synchronously, which proves the function
// exited via the async path rather than (say) crashing or invoking the
// callback inline. This is a tracer-bullet contract.
//
// Wire-up: add `registerThumbnailsTests()` to Tests/main.swift and
// append this file to TEST_SOURCES in tests.sh (orchestrator handles it).

func registerThumbnailsTests() {
    // ── missing-file early return ─────────────────────────────────────────
    test("generate on a non-existent absolute path returns synchronously without firing the completion inline") {
        // The missing-file branch dispatches completion(nil) onto main —
        // it must NOT fire on the calling thread. If a future change ever
        // makes the early return synchronous, this test will flip and the
        // contract needs to be re-examined (Bridge.swift respond paths
        // assume async semantics).
        var fired = false
        Thumbnails.generate(
            path: "/var/empty/definitely-not-a-real-file-\(UUID().uuidString).bin",
            size: CGSize(width: 128, height: 128),
            scale: 2.0,
            representation: "all",
            format: "png",
            quality: 0.85,
            timeoutSeconds: 5.0
        ) { _ in fired = true }
        try expect(!fired, "completion must be queued on main, not invoked synchronously")
    }

    test("generate on an empty path string returns synchronously without firing the completion inline") {
        // Empty path expands to empty — FileManager returns false — same
        // early-return branch as a missing path. Must not crash on the
        // URL(fileURLWithPath:) hop.
        var fired = false
        Thumbnails.generate(
            path: "",
            size: CGSize(width: 64, height: 64),
            scale: 1.0,
            representation: "all",
            format: "png",
            quality: 0.85,
            timeoutSeconds: 5.0
        ) { _ in fired = true }
        try expect(!fired)
    }

    test("generate with a tilde path pointing at a non-existent file returns synchronously") {
        // The expandingTildeInPath hop is the only string transform in the
        // prelude. A bad expansion would either crash or fall through to
        // QL — both observable as a synchronous fire or a throw.
        var fired = false
        Thumbnails.generate(
            path: "~/.stackd-thumbnails-test-\(UUID().uuidString)-missing.bin",
            size: CGSize(width: 128, height: 128),
            scale: 2.0,
            representation: "all",
            format: "png",
            quality: 0.85,
            timeoutSeconds: 5.0
        ) { _ in fired = true }
        try expect(!fired)
    }

    // ── input range tolerance ────────────────────────────────────────────
    test("generate tolerates an unknown representation string on the missing-file path") {
        // representationType(_:) is private but reachable via the public
        // entry. Anything outside {thumbnail, icon, lowQualityThumbnail}
        // must fall through to .all — not crash on an enum lookup.
        var fired = false
        Thumbnails.generate(
            path: "/var/empty/missing-\(UUID().uuidString).bin",
            size: CGSize(width: 128, height: 128),
            scale: 2.0,
            representation: "garbage-not-a-real-type",
            format: "png",
            quality: 0.85,
            timeoutSeconds: 5.0
        ) { _ in fired = true }
        try expect(!fired)
    }

    test("generate tolerates an unknown format string on the missing-file path") {
        // The format branch in encode() is private, but the public entry
        // must at least accept arbitrary strings without throwing — the
        // file-missing branch fires before encode() is ever reached.
        var fired = false
        Thumbnails.generate(
            path: "/var/empty/missing-\(UUID().uuidString).bin",
            size: CGSize(width: 128, height: 128),
            scale: 2.0,
            representation: "all",
            format: "tiff-not-supported",
            quality: 0.85,
            timeoutSeconds: 5.0
        ) { _ in fired = true }
        try expect(!fired)
    }

    test("generate tolerates out-of-range quality values on the missing-file path") {
        // encode() clamps internally with max(0, min(1, quality)). The
        // public entry must not validate quality up-front (the contract
        // is permissive — Bridge.swift hands through whatever JS sent).
        var fired = false
        Thumbnails.generate(
            path: "/var/empty/missing-\(UUID().uuidString).bin",
            size: CGSize(width: 128, height: 128),
            scale: 2.0,
            representation: "all",
            format: "jpeg",
            quality: -5.0,
            timeoutSeconds: 5.0
        ) { _ in fired = true }
        try expect(!fired)

        var fired2 = false
        Thumbnails.generate(
            path: "/var/empty/missing-\(UUID().uuidString).bin",
            size: CGSize(width: 128, height: 128),
            scale: 2.0,
            representation: "all",
            format: "jpeg",
            quality: 99.0,
            timeoutSeconds: 5.0
        ) { _ in fired2 = true }
        try expect(!fired2)
    }

    test("generate tolerates a zero-size CGSize and scale=0 on the missing-file path") {
        // CGSize.zero and scale 0 would be programming errors at the QL
        // boundary, but the missing-file branch must short-circuit before
        // QL ever sees them. Verifies the early-return order: fileExists
        // check precedes Request construction.
        var fired = false
        Thumbnails.generate(
            path: "/var/empty/missing-\(UUID().uuidString).bin",
            size: .zero,
            scale: 0,
            representation: "all",
            format: "png",
            quality: 0.85,
            timeoutSeconds: 5.0
        ) { _ in fired = true }
        try expect(!fired)
    }

    test("generate tolerates a zero / negative timeoutSeconds on the missing-file path") {
        // The timeout watchdog is scheduled via asyncAfter — even with a
        // 0 or negative deadline it can't fire synchronously inside the
        // call frame, so the completion must still be queued, not inline.
        var fired = false
        Thumbnails.generate(
            path: "/var/empty/missing-\(UUID().uuidString).bin",
            size: CGSize(width: 128, height: 128),
            scale: 2.0,
            representation: "all",
            format: "png",
            quality: 0.85,
            timeoutSeconds: 0
        ) { _ in fired = true }
        try expect(!fired)
    }
}
