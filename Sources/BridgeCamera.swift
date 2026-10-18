import Foundation

/// Camera primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1). Three entries:
///
///   - `camera.frame` — one-shot grab via AVCaptureSession. Triggers the
///     Camera TCC prompt the first time. Pure `.custom(...)` into
///     `Sources/DataSources/Camera.swift`; no per-instance state captured
///     beyond `respond`.
///
///   - `camera.stream.start` / `camera.stream.stop` — long-lived
///     AVCaptureSession that pushes one dataURL payload per tick to a
///     per-handle channel ("camera:stream:<id>"). Same handle-table +
///     scope-drain pattern as bonjour.browse. JS `sd.camera.stream()`
///     wraps the returned id as `{ id, subscribe, stop }`.
///
/// Streams live in the Bridge's `cameraStreamHandles` table; the scope
/// drain on stack unload stops every surviving stream so a reload doesn't
/// strand the camera LED on.
extension Bridge {
    /// Camera primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func cameraPrimitives() -> [Primitive] {
        return [
            // Camera — one-shot frame grab. Triggers the Camera TCC prompt the
            // first time. `deviceId` matches sd.camera channel ids; nil = system
            // default. Format jpeg/png, quality 0..1 (jpeg only). Returns
            // { dataURL, width, height } or null. Pairs with sd.vision.*.
            .custom("camera.frame", permission: "camera") { bridge, body, requestId in
                let deviceId = body["deviceId"] as? String
                let format   = body["format"]   as? String ?? "jpeg"
                let quality  = body["quality"]  as? Double ?? 0.85
                let timeout  = body["timeoutSeconds"] as? Double ?? 3.0
                Camera.frame(deviceId: deviceId, format: format,
                             quality: quality, timeoutSeconds: timeout) { [weak bridge] result in
                    bridge?.respond(requestId: requestId, value: result as Any? ?? NSNull())
                }
            },

            // Camera streaming — long-lived AVCaptureSession that pushes one
            // dataURL payload per tick to a per-handle channel ("camera:stream:<id>").
            // Same handle-table + scope-drain pattern as bonjour.browse.start.
            // The first call triggers the Camera TCC prompt iff a prior
            // camera.frame hasn't already granted it. fps defaults to 10 and
            // is capped at 60 — caps documented on CameraStream.clampedFps.
            // Returns the handle id (JS wraps it as { id, subscribe, stop }),
            // or null if the device can't be opened.
            .custom("camera.stream.start", permission: "camera") { bridge, body, requestId in
                let deviceId = body["deviceId"] as? String
                let format   = CameraStream.normalizedFormat(body["format"] as? String)
                let quality  = CameraStream.clampedQuality(body["quality"] as? Double)
                let fps      = CameraStream.clampedFps(body["fps"] as? Double)
                let id = bridge.cameraStreamHandles.mintId()
                let channel = "camera:stream:\(id)"
                let stream = Camera.openStream(
                    deviceId: deviceId,
                    format: format,
                    quality: quality,
                    fps: fps
                ) { [weak bridge] payload in
                    guard let bridge = bridge else { return }
                    let json = Bridge.jsonify(payload)
                    bridge.push(channel: channel, json: json)
                }
                guard let stream = stream else {
                    bridge.respond(requestId: requestId, value: NSNull()); return
                }
                bridge.cameraStreamHandles[id] = Token { stream.stop() }
                bridge.respond(requestId: requestId, value: id)
            },
            .syncBridge("camera.stream.stop", permission: "camera", denyValue: false) { b, body in
                guard let id = body["id"] as? Int else { return false }
                return b.cameraStreamHandles.cancel(id)
            },
        ]
    }
}
