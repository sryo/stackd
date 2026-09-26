import Foundation

// Tests for the pure helpers in Camera.swift. AVCaptureSession is impure
// (hardware-coupled, triggers TCC, requires entitlements), so the streaming
// pipeline itself isn't tested here — only the deterministic primitives
// that gate it: fps throttling, format clamping, quality clamping, and
// fps clamping.

func registerCameraStreamTests() {
    // ── shouldEmit ─────────────────────────────────────────────────────────
    test("shouldEmit emits once the gap reaches 1/fps and drops before it") {
        try expect(CameraStream.shouldEmit(now: 1.2, lastEmit: 1.0, fps: 10), "200ms gap at 10fps")
        try expect(!CameraStream.shouldEmit(now: 1.05, lastEmit: 1.0, fps: 10), "50ms gap at 10fps")
        try expect(CameraStream.shouldEmit(now: 0.020, lastEmit: 0, fps: 60), "20ms gap at 60fps")
        try expect(!CameraStream.shouldEmit(now: 0.010, lastEmit: 0, fps: 60), "10ms gap at 60fps")
    }

    test("shouldEmit emits at exactly the interval (>=, not >)") {
        // Exactly representable values so the boundary isn't decided by
        // float rounding: 1/4 = 0.25 and 0.75 - 0.5 = 0.25.
        try expect(CameraStream.shouldEmit(now: 0.75, lastEmit: 0.5, fps: 4))
    }

    test("shouldEmit with fps <= 0 always returns true (no gate)") {
        // fps <= 0 disables throttling — the caller asked for raw cadence.
        try expect(CameraStream.shouldEmit(now: 0.001, lastEmit: 0, fps: 0))
        try expect(CameraStream.shouldEmit(now: 1.0, lastEmit: 0.999, fps: -1))
    }

    // ── normalizedFormat ───────────────────────────────────────────────────
    test("normalizedFormat passes jpeg/png through and collapses jpg to jpeg") {
        try expectEqual(CameraStream.normalizedFormat("jpeg"), "jpeg")
        try expectEqual(CameraStream.normalizedFormat("png"),  "png")
        try expectEqual(CameraStream.normalizedFormat("jpg"),  "jpeg")
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
