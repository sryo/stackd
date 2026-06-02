import Foundation
import AudioToolbox
import CoreAudio

// Tests for the read-only + pure surface of Audio.swift.
//
// Out of scope by design:
//   - setVolume / setMuted / setInputVolume / setInputMuted / setDefaultDevice —
//     these MUTATE the user's actual audio state. Calling them during a test
//     run would flip the user's volume / mute / default device. The clamp
//     math lives inside a private setter, so it can't be exercised through
//     the public API without mutating state — left uncovered intentionally.
//   - AudioObserver / AudioInputObserver / MediaObserver — observer
//     lifecycle drives real CoreAudio listener blocks. Covered by integration
//     reality, not unit tests.
//
// In scope:
//   - Scope enum mapping → CoreAudio scope + default-device selector constants.
//   - volumeAddress / muteAddress → pure address builders, scope-routed.
//   - current() / currentInput() → dict shape contract (keys + types) that
//     JS consumers depend on. Real values come from the user's hardware, so
//     we assert shape only, never magnitudes or device names.
//   - devices(scope:) → list-of-dicts shape contract, key presence, type
//     stability, and the isDefault invariant (≤1 default per scope).
//   - defaultOutputDevice / defaultInputDevice → AudioDeviceID? probe. Every
//     Mac with working audio has both; if absent, we don't fail the test,
//     we skip the shape assertions that depend on them.

func registerAudioTests() {
    // MARK: - Scope enum (pure mapping)

    test("Scope.output maps to kAudioDevicePropertyScopeOutput") {
        try expectEqual(Audio.Scope.output.coreAudioScope, kAudioDevicePropertyScopeOutput)
    }

    test("Scope.input maps to kAudioDevicePropertyScopeInput") {
        try expectEqual(Audio.Scope.input.coreAudioScope, kAudioDevicePropertyScopeInput)
    }

    test("Scope.output default selector is DefaultOutputDevice") {
        try expectEqual(
            Audio.Scope.output.defaultDeviceSelector,
            kAudioHardwarePropertyDefaultOutputDevice
        )
    }

    test("Scope.input default selector is DefaultInputDevice") {
        try expectEqual(
            Audio.Scope.input.defaultDeviceSelector,
            kAudioHardwarePropertyDefaultInputDevice
        )
    }

    // MARK: - Address builders (pure)

    test("volumeAddress routes selector + scope per direction") {
        let outAddr = Audio.volumeAddress(scope: .output)
        let inAddr  = Audio.volumeAddress(scope: .input)
        // Selector is the virtual-main-volume constant for BOTH scopes —
        // the only thing that differs is mScope.
        try expectEqual(outAddr.mSelector, kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        try expectEqual(inAddr.mSelector,  kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        try expectEqual(outAddr.mScope, kAudioDevicePropertyScopeOutput)
        try expectEqual(inAddr.mScope,  kAudioDevicePropertyScopeInput)
        try expectEqual(outAddr.mElement, kAudioObjectPropertyElementMain)
        try expectEqual(inAddr.mElement,  kAudioObjectPropertyElementMain)
    }

    test("muteAddress routes selector + scope per direction") {
        let outAddr = Audio.muteAddress(scope: .output)
        let inAddr  = Audio.muteAddress(scope: .input)
        try expectEqual(outAddr.mSelector, kAudioDevicePropertyMute)
        try expectEqual(inAddr.mSelector,  kAudioDevicePropertyMute)
        try expectEqual(outAddr.mScope, kAudioDevicePropertyScopeOutput)
        try expectEqual(inAddr.mScope,  kAudioDevicePropertyScopeInput)
    }

    test("static mainVolumeAddress is scoped to output (back-compat for AudioObserver)") {
        // AudioObserver passes &Audio.mainVolumeAddress directly into
        // CoreAudio Add/Remove pairs. If this scope flips, the output
        // observer silently watches the wrong direction.
        try expectEqual(Audio.mainVolumeAddress.mSelector, kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        try expectEqual(Audio.mainVolumeAddress.mScope, kAudioDevicePropertyScopeOutput)
    }

    // MARK: - current() / currentInput() dict shape

    test("current() returns the volume/muted/deviceName key set") {
        let dict = Audio.current()
        try expect(dict["volume"]     != nil, "missing 'volume' key")
        try expect(dict["muted"]      != nil, "missing 'muted' key")
        try expect(dict["deviceName"] != nil, "missing 'deviceName' key")
    }

    test("current() volume is Float-or-null, muted is Bool, deviceName is String-or-null") {
        // Stacks pattern-match on these types — a regression to e.g.
        // NSNumber-wrapped Bool would silently break sd.volume HUDs.
        let dict = Audio.current()
        // volume: Float OR NSNull (no device case)
        let v = dict["volume"]!
        try expect(v is Float || v is NSNull,
                   "volume should be Float or NSNull, got \(type(of: v))")
        // muted: always Bool (defaults to false when no device)
        try expect(dict["muted"]! is Bool,
                   "muted should be Bool, got \(type(of: dict["muted"]!))")
        // deviceName: String OR NSNull
        let n = dict["deviceName"]!
        try expect(n is String || n is NSNull,
                   "deviceName should be String or NSNull, got \(type(of: n))")
    }

    test("currentInput() returns the same key set as current()") {
        // Mirror contract — the input HUD reuses the output HUD's shape.
        let dict = Audio.currentInput()
        try expect(dict["volume"]     != nil, "missing 'volume' key")
        try expect(dict["muted"]      != nil, "missing 'muted' key")
        try expect(dict["deviceName"] != nil, "missing 'deviceName' key")
        try expect(dict["muted"]! is Bool,
                   "input muted should be Bool, got \(type(of: dict["muted"]!))")
    }

    // MARK: - devices(scope:) list shape

    test("devices(scope: .output) returns a list whose rows expose the documented keys") {
        // Every Mac with working audio has at least one output device. If
        // the list is empty we don't fail the run — CI without audio HW
        // is conceivable — but we DO assert shape on whatever rows exist.
        let rows = Audio.devices(scope: .output)
        for row in rows {
            try expect(row["id"]            is Int,    "id should be Int, got \(type(of: row["id"] ?? "nil"))")
            try expect(row["name"]          is String, "name should be String")
            try expect(row["isDefault"]     is Bool,   "isDefault should be Bool")
            // Nullable string fields: must be present, must be String or NSNull
            let tt = row["transportType"]!
            try expect(tt is String || tt is NSNull,
                       "transportType should be String or NSNull, got \(type(of: tt))")
            let mf = row["manufacturer"]!
            try expect(mf is String || mf is NSNull,
                       "manufacturer should be String or NSNull, got \(type(of: mf))")
            let u = row["uid"]!
            try expect(u is String || u is NSNull,
                       "uid should be String or NSNull, got \(type(of: u))")
        }
    }

    test("devices(scope:) lists at most one default device per scope") {
        // The isDefault flag is computed against defaultOutputDevice() /
        // defaultInputDevice() — CoreAudio invariant is exactly one default
        // per direction, so a list with ≥2 isDefault=true rows means the
        // filtering logic regressed (e.g. comparing AudioDeviceID against
        // the wrong scope's default).
        let outputDefaults = Audio.devices(scope: .output).filter { ($0["isDefault"] as? Bool) == true }
        let inputDefaults  = Audio.devices(scope: .input).filter  { ($0["isDefault"] as? Bool) == true }
        try expect(outputDefaults.count <= 1,
                   "expected ≤1 default output, got \(outputDefaults.count)")
        try expect(inputDefaults.count <= 1,
                   "expected ≤1 default input, got \(inputDefaults.count)")
    }

    test("devices(scope:) returns the same row count when called back-to-back") {
        // Cheap stability check: a hot enumeration shouldn't drop/add rows
        // between consecutive reads on a stable hardware state. Catches a
        // class of "first call seeds state, second call sees fewer" bugs.
        let a = Audio.devices(scope: .output)
        let b = Audio.devices(scope: .output)
        try expectEqual(a.count, b.count)
    }

    // MARK: - defaultOutputDevice / defaultInputDevice probes

    test("defaultOutputDevice round-trips through name(of:) when present") {
        // If the host has a default output device (every Mac with audio
        // does), name(of:) must return a non-empty string — the rest of
        // current() depends on it.
        guard let id = Audio.defaultOutputDevice() else {
            // Headless CI without audio: skip rather than fail.
            return
        }
        let n = Audio.name(of: id)
        try expect(n != nil && !(n!.isEmpty),
                   "default output device should have a non-empty name, got \(String(describing: n))")
    }

    test("Media.nowPlaying: completion is async, never fires inline") {
        // Whether MediaRemote.getNowPlayingInfo is loadable or not, the
        // completion must hop a queue before firing — Bridge.respond would
        // otherwise be re-entered before the dispatch tool returned, and
        // chained sd.media.* calls could see inverted ordering. Same
        // contract as Vision/Thumbnails (different queue, same async-ness).
        var fired = false
        Media.nowPlaying { _ in fired = true }
        try expect(!fired, "Media.nowPlaying completion must not fire synchronously")
    }
}
