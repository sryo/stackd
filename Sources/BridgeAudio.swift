import Foundation
import CoreAudio  // AudioDeviceID — used by sd.audio.setDefaultDevice

/// Audio primitive group — extracted from Bridge.swift as part of the A1
/// god-object breakup (architect finding #1). Every entry is a pure
/// `.sync(...)` call into `Sources/DataSources/Audio.swift`; no Bridge
/// instance state is captured, so this file holds nothing but a static
/// builder method that returns the registrations.
///
/// All six entries are gated by the `"audio"` permission and mirror
/// CoreAudio's "default device, virtual main" shape: setVolume/setMuted
/// touch the output device, the *Input variants touch the input device,
/// devices() enumerates per-scope, setDefaultDevice routes either way.
/// None of them open an audio stream, so the microphone TCC prompt is
/// not triggered.
extension Bridge {
    /// Audio primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func audioPrimitives() -> [Primitive] {
        return [
            // Bool side-effect ops, deny → false. Output ops touch the
            // default output device's "virtual main" volume / mute. Input
            // ops mirror the same shape for the default input device
            // (CoreAudio property API only — does NOT open a stream, so
            // the microphone TCC prompt is not triggered).
            .sync("audio.setVolume", permission: "audio", denyValue: false) { body in
                Audio.setVolume(Float((body["value"] as? Double) ?? 0))
            },
            .sync("audio.setMuted", permission: "audio", denyValue: false) { body in
                Audio.setMuted((body["value"] as? Bool) ?? false)
            },
            .sync("audio.setInputVolume", permission: "audio", denyValue: false) { body in
                Audio.setInputVolume(Float((body["value"] as? Double) ?? 0))
            },
            .sync("audio.setInputMuted", permission: "audio", denyValue: false) { body in
                Audio.setInputMuted((body["value"] as? Bool) ?? false)
            },
            // Per-scope device enumeration. Returns [{id, name,
            // manufacturer?, transportType?, uid?, isDefault}, ...] — id
            // is the AudioDeviceID as Int so JS can pass it back through
            // `setDefaultDevice`. Filtered to devices that actually have
            // streams in the requested direction (an output-only device
            // doesn't appear in the input list).
            .sync("audio.devices", permission: "audio", denyValue: [[String: Any]]()) { body in
                let scope: Audio.Scope = (body["scope"] as? String) == "input" ? .input : .output
                return Audio.devices(scope: scope)
            },
            .sync("audio.setDefaultDevice", permission: "audio", denyValue: false) { body in
                guard let id = body["id"] as? Int else { return false }
                let scope: Audio.Scope = (body["scope"] as? String) == "input" ? .input : .output
                return Audio.setDefaultDevice(id: AudioDeviceID(id), scope: scope)
            },
        ]
    }
}
