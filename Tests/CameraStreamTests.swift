import Foundation

// Tests for the pure helpers in Camera.swift. AVCaptureSession is impure
// (hardware-coupled, triggers TCC, requires entitlements), so the streaming
// pipeline itself isn't tested here — only the deterministic primitives
// that gate it: fps throttling, format clamping, quality clamping, and
// fps clamping.
//
// Wire-up: add `registerCameraStreamTests()` to Tests/main.swift and append
// this file to TEST_SOURCES in tests.sh (orchestrator handles this).

func registerCameraStreamTests() {
    // ── shouldEmit ─────────────────────────────────────────────────────────
    test("shouldEmit at fps=10 with a 200ms gap returns true") {
        // 1/10 = 100ms interval; 200ms gap is well past it.
        try expect(CameraStream.shouldEmit(now: 1.2, lastEmit: 1.0, fps: 10))
    }

    test("shouldEmit at fps=10 with a 50ms gap returns false") {
        // 50ms < 100ms interval — drop the buffer.
        try expect(!CameraStream.shouldEmit(now: 1.05, lastEmit: 1.0, fps: 10))
    }

    test("shouldEmit at fps=10 with exactly the interval returns true") {
        // Boundary case: >= 1/fps must emit, not drop.
        try expect(CameraStream.shouldEmit(now: 1.1, lastEmit: 1.0, fps: 10))
    }

    test("shouldEmit at fps=0 always returns true (no gate)") {
        // fps <= 0 disables throttling — the caller asked for raw cadence.
        try expect(CameraStream.shouldEmit(now: 0.001, lastEmit: 0, fps: 0))
        try expect(CameraStream.shouldEmit(now: 1.0, lastEmit: 0.999, fps: 0))
    }

    test("shouldEmit at fps=60 with a 20ms gap returns true") {
        // 1/60 ≈ 16.6ms; 20ms is just past it.
        try expect(CameraStream.shouldEmit(now: 0.020, lastEmit: 0, fps: 60))
    }

    // ── normalizedFormat ───────────────────────────────────────────────────
    test("normalizedFormat passes jpeg/png through") {
        try expectEqual(CameraStream.normalizedFormat("jpeg"), "jpeg")
        try expectEqual(CameraStream.normalizedFormat("png"),  "png")
    }

    test("normalizedFormat collapses jpg alias to jpeg") {
        try expectEqual(CameraStream.normalizedFormat("jpg"), "jpeg")
    }

    test("normalizedFormat falls back to jpeg for nil / empty / unknown") {
        try expectEqual(CameraStream.normalizedFormat(nil),     "jpeg")
        try expectEqual(CameraStream.normalizedFormat(""),      "jpeg")
        try expectEqual(CameraStream.normalizedFormat("heic"),  "jpeg")
        try expectEqual(CameraStream.normalizedFormat("WEBP"),  "jpeg")
    }

    // ── clampedQuality ─────────────────────────────────────────────────────
    test("clampedQuality passes in-range values through") {
        try expectEqual(CameraStream.clampedQuality(0.5),  0.5)
        try expectEqual(CameraStream.clampedQuality(0.0),  0.0)
        try expectEqual(CameraStream.clampedQuality(1.0),  1.0)
    }

    test("clampedQuality clips out-of-range values") {
        try expectEqual(CameraStream.clampedQuality(-0.1), 0.0)
        try expectEqual(CameraStream.clampedQuality(1.5),  1.0)
        try expectEqual(CameraStream.clampedQuality(100),  1.0)
    }

    test("clampedQuality defaults nil to 0.85") {
        try expectEqual(CameraStream.clampedQuality(nil), 0.85)
    }

    // ── clampedFps ─────────────────────────────────────────────────────────
    test("clampedFps passes in-window values through") {
        try expectEqual(CameraStream.clampedFps(10), 10)
        try expectEqual(CameraStream.clampedFps(30), 30)
        try expectEqual(CameraStream.clampedFps(60), 60)
    }

    test("clampedFps caps above-60 values at 60") {
        try expectEqual(CameraStream.clampedFps(120), 60)
        try expectEqual(CameraStream.clampedFps(1000), 60)
    }

    test("clampedFps defaults nil / non-positive to 10") {
        try expectEqual(CameraStream.clampedFps(nil),  10)
        try expectEqual(CameraStream.clampedFps(0),    10)
        try expectEqual(CameraStream.clampedFps(-5),   10)
    }
}
