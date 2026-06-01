import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

// Streaming-frame variant of sd.camera. The one-shot `Camera.frame(...)` in
// Devices.swift opens an AVCaptureSession, waits for the first buffer, and
// tears the session down. That round-trip is fine for the polled hydration-
// tracker pattern (~2s tick), but it pays the session-open cost every call
// — and the camera LED blinks on/off rather than staying solid. For real
// live processing (face tracking, body-pose overlays, perceptual diffing)
// the caller wants the session kept warm and frames pushed at a steady fps.
//
// `Camera.Stream` is that long-lived path. The Bridge holds a per-stack
// handle table (`cameraStreamHandles`); the JS surface (`sd.camera.stream`)
// mirrors `sd.bonjour.browse` — handle id + subscribe(fn) + stop(). On stack
// unload the scope drain calls `stop()` which tears the session down so a
// hot-reload doesn't leak the capture device.
//
// TCC: same prompt as Camera.frame. AVCaptureSession.startRunning is what
// raises the macOS Camera permission sheet; if the user already granted
// (e.g. via a prior `frame()` call) the stream starts without a re-prompt.
//
// Format / quality / encoding are intentionally identical to the one-shot
// path — same CGImageDestination call, same dataURL shape. Stacks can swap
// `await sd.camera.frame()` for `sd.camera.stream().subscribe(fn)` without
// touching downstream processing code.

enum CameraStream {
    /// Pure throttle-gate. Returns true when `now - lastEmit >= 1/fps`, i.e.
    /// the previous emission is old enough that the next frame should fire.
    /// fps <= 0 is treated as "emit every frame" (no gate). Used by the
    /// sample-buffer delegate to drop buffers that arrive faster than the
    /// requested cadence — AVCaptureDevice's native rate (30/60fps) is
    /// usually well above what JS-side rendering wants to consume.
    static func shouldEmit(now: Double, lastEmit: Double, fps: Double) -> Bool {
        if fps <= 0 { return true }
        let interval = 1.0 / fps
        return (now - lastEmit) >= interval
    }

    /// Clamp the JS-supplied format string to {"jpeg", "png"}. Anything else
    /// falls back to "jpeg" — the cheaper default. Matches the one-shot
    /// path's behavior (CGImageDestination silently fails on an unknown
    /// UTType; we'd rather degrade than return nil here).
    static func normalizedFormat(_ raw: String?) -> String {
        switch raw {
        case "png": return "png"
        case "jpeg", "jpg", nil, "": return "jpeg"
        default: return "jpeg"
        }
    }

    /// Clamp the JS-supplied JPEG quality to [0, 1]. nil → 0.85 (same default
    /// as Camera.frame). Out-of-range values clip rather than reject — the
    /// caller asked for "as compressed as possible" / "lossless-ish" and we
    /// hand back the closest legal value.
    static func clampedQuality(_ raw: Double?) -> Double {
        let q = raw ?? 0.85
        return max(0, min(1, q))
    }

    /// Clamp the JS-supplied fps to a sane window. nil / non-positive →
    /// default 10fps. Capping at 60 avoids the no-throttle edge case where
    /// a 60Hz native device would push every buffer through evaluateJS
    /// (which dominates the per-frame cost — base64 + main-thread hop).
    /// Stacks that want raw device cadence can pass a large number; 60 is
    /// already higher than any built-in camera's standard rate.
    static func clampedFps(_ raw: Double?) -> Double {
        let f = raw ?? 10
        if f <= 0 { return 10 }
        return min(f, 60)
    }
}

extension Camera {
    /// Long-lived AVCaptureSession + sample-buffer delegate. One instance
    /// per active stream handle. The Bridge owns the instance via a Token
    /// stored in `cameraStreamHandles`; cancel() calls `stop()` which
    /// detaches the delegate and stops the session (turning the camera LED
    /// off and releasing the device for other apps).
    ///
    /// Self-retain pattern mirrors OneShotGrabber: the delegate is held by
    /// the AVCaptureVideoDataOutput weakly, so the Stream class keeps a
    /// strong reference to itself in `retain` from start() until stop().
    final class Stream: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let session = AVCaptureSession()
        private let output  = AVCaptureVideoDataOutput()
        private let queue   = DispatchQueue(label: "stackd.camera.stream")
        private let device: AVCaptureDevice
        private let format: String
        private let quality: Double
        private let fps: Double
        private let onFrame: ([String: Any]) -> Void
        private var lastEmitTs: Double = 0
        private var stopped = false
        private var retain: Stream?

        init(device: AVCaptureDevice,
             format: String,
             quality: Double,
             fps: Double,
             onFrame: @escaping ([String: Any]) -> Void) {
            self.device  = device
            self.format  = format
            self.quality = quality
            self.fps     = fps
            self.onFrame = onFrame
        }

        /// Open the session. Returns false if the device input couldn't be
        /// added (rare — usually means the device disappeared between
        /// AVCaptureDevice lookup and start). startRunning is the call that
        /// triggers the Camera TCC prompt on first use; the prompt is shared
        /// with the one-shot Camera.frame path so a prior grant covers this.
        @discardableResult
        func start() -> Bool {
            retain = self
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { stop(); return false }
                session.addInput(input)

                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_32BGRA)
                ]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else { stop(); return false }
                session.addOutput(output)

                session.startRunning()
                return true
            } catch {
                stop()
                return false
            }
        }

        /// Tear the session down. Safe to call multiple times — guarded by
        /// `stopped`. Detaches the sample-buffer delegate to break the
        /// retain cycle (output → delegate (self) → output's owning Stream),
        /// stops the session, and drops the self-retain so ARC can collect.
        func stop() {
            guard !stopped else { return }
            stopped = true
            output.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
            retain = nil
        }

        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard !stopped,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            let now = CACurrentMediaTime()
            if !CameraStream.shouldEmit(now: now, lastEmit: lastEmitTs, fps: fps) {
                return
            }
            lastEmitTs = now
            guard var payload = Camera.encodeFrame(pixelBuffer: pixelBuffer,
                                                   format: format,
                                                   quality: quality)
            else { return }
            payload["ts"] = now
            onFrame(payload)
        }
    }

    /// Shared CVPixelBuffer → dataURL helper. Mirrors the one-shot path's
    /// encoding exactly (same CGImageDestination call, same key shape) so
    /// stacks can swap `.frame()` ↔ `.stream()` without changing how they
    /// consume the result. Extracted here so future encoding tweaks
    /// (HEIC support, embedded EXIF) land in one place.
    fileprivate static func encodeFrame(pixelBuffer: CVPixelBuffer,
                                        format: String,
                                        quality: Double) -> [String: Any]? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        let isPNG = (format == "png")
        let utType = (isPNG ? "public.png" : "public.jpeg") as CFString
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, utType, 1, nil
        ) else { return nil }
        let props: [CFString: Any] = isPNG ? [:] : [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let base64 = (data as Data).base64EncodedString()
        let mime = isPNG ? "image/png" : "image/jpeg"
        return [
            "dataURL": "data:\(mime);base64,\(base64)",
            "width":   cgImage.width,
            "height":  cgImage.height
        ]
    }

    /// Open a stream for `deviceId` (matches `sd.camera` channel entries;
    /// nil → system default video device). Returns nil if the device can't
    /// be resolved or the session refused to start. The returned Stream is
    /// already running — the caller's onFrame closure will start receiving
    /// `{ dataURL, width, height, ts }` payloads up to `fps` times per
    /// second. Call `.stop()` on the returned handle to tear down.
    static func openStream(deviceId: String?,
                           format: String,
                           quality: Double,
                           fps: Double,
                           onFrame: @escaping ([String: Any]) -> Void) -> Stream? {
        let device: AVCaptureDevice?
        if let id = deviceId, !id.isEmpty {
            device = AVCaptureDevice(uniqueID: id)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let device = device else { return nil }
        let stream = Stream(device: device,
                            format: format,
                            quality: quality,
                            fps: fps,
                            onFrame: onFrame)
        guard stream.start() else { return nil }
        return stream
    }
}
