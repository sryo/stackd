import Foundation
import CoreGraphics
import JavaScriptCore

// Tests for `WindowStream` in Sources/DataSources/Windows.swift.
//
// The stream's capture source is injected, so the frame pipeline (downscale,
// encode, unchanged-frame skip, stop) runs on synthetic CGImages driven by
// `tick()`. The runtime half (Runtime/src/11-windows.js) is driven through
// JSHarness with a stubbed postMessage. The live source — CGSHWCaptureWindowList against a real window
// id — and the timer cadence are runtime-verified only.

private func solidImage(width: Int, height: Int, gray: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

func registerWindowStreamTests() {
    test("WindowStream.clampedFps defaults to 10 and caps at 30") {
        try expectEqual(WindowStream.clampedFps(nil), 10)
        try expectEqual(WindowStream.clampedFps(0), 10)
        try expectEqual(WindowStream.clampedFps(-3), 10)
        try expectEqual(WindowStream.clampedFps(15), 15)
        try expectEqual(WindowStream.clampedFps(120), 30)
    }

    test("WindowStream.scaledSize fits maxWidth, keeps aspect, never upscales") {
        let a = WindowStream.scaledSize(width: 1000, height: 500, maxWidth: 200)
        try expectEqual(a.width, 200); try expectEqual(a.height, 100)
        let b = WindowStream.scaledSize(width: 100, height: 50, maxWidth: 200)
        try expectEqual(b.width, 100); try expectEqual(b.height, 50)
        let c = WindowStream.scaledSize(width: 640, height: 480, maxWidth: nil)
        try expectEqual(c.width, 640); try expectEqual(c.height, 480)
        let d = WindowStream.scaledSize(width: 1000, height: 1, maxWidth: 10)
        try expectEqual(d.height, 1, "height floors at 1px")
    }

    test("WindowStream.tick emits a downscaled jpeg frame") {
        var frames: [[String: Any]] = []
        let s = WindowStream(fps: 10, maxWidth: 80, quality: 0.7,
                             capture: { solidImage(width: 400, height: 200, gray: 0.5) },
                             emit: { frames.append($0) })
        s.tick()
        try expectEqual(frames.count, 1)
        try expectEqual(frames[0]["width"] as? Int, 80)
        try expectEqual(frames[0]["height"] as? Int, 40)
        try expect((frames[0]["dataURL"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true,
                   "expected a jpeg dataURL")
    }

    test("WindowStream.tick skips a frame identical to the last one emitted") {
        var frames: [[String: Any]] = []
        var gray: CGFloat = 0.2
        let s = WindowStream(fps: 10, maxWidth: nil, quality: 0.7,
                             capture: { solidImage(width: 20, height: 20, gray: gray) },
                             emit: { frames.append($0) })
        s.tick(); s.tick()
        try expectEqual(frames.count, 1, "unchanged content")
        gray = 0.9
        s.tick()
        try expectEqual(frames.count, 2, "changed content")
    }

    test("WindowStream.tick emits nothing when the capture fails") {
        var frames = 0
        let s = WindowStream(fps: 10, maxWidth: nil, quality: 0.7,
                             capture: { nil }, emit: { _ in frames += 1 })
        s.tick()
        try expectEqual(frames, 0)
    }

    test("WindowStream emits nothing after stop") {
        var frames = 0
        var gray: CGFloat = 0
        let s = WindowStream(fps: 10, maxWidth: nil, quality: 0.7,
                             capture: { gray += 0.1; return solidImage(width: 8, height: 8, gray: gray) },
                             emit: { _ in frames += 1 })
        s.tick()
        s.stop()
        s.tick()
        try expectEqual(frames, 1)
    }

    test("WindowStream start drives ticks on its own timer") {
        let lock = NSLock()
        var frames = 0
        var gray: CGFloat = 0
        let s = WindowStream(fps: 30, maxWidth: nil, quality: 0.7,
                             capture: { gray = gray >= 1 ? 0 : gray + 0.1
                                        return solidImage(width: 8, height: 8, gray: gray) },
                             emit: { _ in lock.lock(); frames += 1; lock.unlock() })
        s.start()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock(); let n = frames; lock.unlock()
            if n >= 3 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        s.stop()
        lock.lock(); let n = frames; lock.unlock()
        try expect(n >= 3, "expected >= 3 timer-driven frames, got \(n)")
    }

    test("sd.windows.stream: start payload, pre-resolve subscriber, stop") {
        let ctx = JSHarness.context
        ctx.evaluateScript("""
        globalThis.__ws = { real: window.webkit.messageHandlers.sd.postMessage, sent: [], got: [], s: null };
        window.webkit.messageHandlers.sd.postMessage = (p) => {
          __ws.sent.push(p);
          if (p.type === "windows.stream.start") Promise.resolve().then(() => window.__sd_response(p.requestId, 77));
        };
        __ws.s = sd.windows.stream(1234, { fps: 15, width: 280 });
        __ws.s.subscribe((f) => __ws.got.push(f.dataURL));
        __ws.late = [];
        """)
        try expectEqual(ctx.evaluateScript("__ws.sent[0].type")?.toString(), "windows.stream.start")
        try expectEqual(ctx.evaluateScript("__ws.sent[0].windowId")?.toInt32(), 1234)
        try expectEqual(ctx.evaluateScript("__ws.sent[0].fps")?.toInt32(), 15)
        try expectEqual(ctx.evaluateScript("__ws.sent[0].width")?.toInt32(), 280)
        try expectEqual(ctx.evaluateScript("__ws.s.id")?.toInt32(), 77)
        ctx.evaluateScript("""
        window.__sd_push("windows:stream:77", { dataURL: "data:a", width: 1, height: 1 });
        window.__sd_push("windows:stream:78", { dataURL: "data:other", width: 1, height: 1 });
        """)
        ctx.evaluateScript("__ws.s.subscribe((f) => __ws.late.push(f.dataURL));")
        try expectEqual(ctx.evaluateScript("__ws.late.join(',')")?.toString(), "data:a",
                        "a post-resolve subscriber gets the current frame, never null")
        ctx.evaluateScript("__ws.s.stop();")
        ctx.evaluateScript("__ws.stopSent = __ws.sent.slice(1).map(p => [p.type, p.id]);")
        ctx.evaluateScript("window.webkit.messageHandlers.sd.postMessage = __ws.real;")
        try expectEqual(ctx.evaluateScript("__ws.got.join(',')")?.toString(), "data:a")
        try expectEqual(ctx.evaluateScript("JSON.stringify(__ws.stopSent)")?.toString(),
                        "[[\"windows.stream.stop\",77]]")
    }
}
