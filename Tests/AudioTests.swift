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

    // MARK: - Media.parseScriptedResult (Spotify / osascript fallback)

    test("parseScriptedResult: empty / whitespace input returns nil") {
        try expect(Media.parseScriptedResult("", bundleId: "com.spotify.client") == nil,
                   "empty input should yield nil (no current track)")
        try expect(Media.parseScriptedResult("   \n", bundleId: "com.spotify.client") == nil,
                   "whitespace-only input should yield nil")
    }

    test("parseScriptedResult: leading-tab (empty title) with content elsewhere returns nil") {
        // Spotify can emit a row with metadata but a blank title field. The
        // parser must reject these — otherwise the bar would render a stale
        // " · Artist" entry with no track name. The earlier "all tabs"
        // version of this test was incorrect: `trimmingCharacters` strips
        // tabs (they're whitespace), so the input collapsed to "" and hit
        // the empty short-circuit, never exercising the !parts[0].isEmpty
        // guard. This input keeps content past the title so the guard
        // actually fires.
        try expect(Media.parseScriptedResult("\tArtist\tAlbum\t100\t10\tplaying", bundleId: "com.spotify.client") == nil,
                   "blank-title-with-content should yield nil")
    }

    test("parseScriptedResult: whitespace-only title returns nil") {
        // Per-field whitespace check — "   " is rejected the same as "".
        try expect(Media.parseScriptedResult("   \tArtist", bundleId: "com.spotify.client") == nil,
                   "whitespace-only title should yield nil")
    }

    test("parseScriptedResult: whitespace-only artist/album are dropped, not emitted") {
        // The bar's `m.artist ? "X · " + m.artist : "X"` ternary is truthy
        // on "   " — so a non-trim emit would render "Song ·    ·    ".
        let out = Media.parseScriptedResult("Song\t   \t   \t1000\t0.5\tplaying",
                                            bundleId: "com.spotify.client")
        try expect(out != nil)
        try expectEqual(out!["title"] as? String, "Song")
        try expect(out!["artist"] == nil, "whitespace-only artist should be dropped")
        try expect(out!["album"]  == nil, "whitespace-only album should be dropped")
    }

    test("parseScriptedResult: title-only input yields playing+title, no artist/album") {
        let out = Media.parseScriptedResult("Just A Title", bundleId: "com.spotify.client")
        try expect(out != nil, "title-only should parse")
        try expectEqual(out!["title"] as? String, "Just A Title")
        // No 6th field → default to playing=true (legacy script only emitted
        // when state was playing, so any output meant playing).
        try expectEqual(out!["playing"] as? Bool, true)
        try expect(out!["artist"] == nil, "no artist field for title-only input")
        try expect(out!["album"]  == nil, "no album field for title-only input")
    }

    test("parseScriptedResult: 6th-field playState=paused yields playing=false") {
        // The current script emits player state as the 6th field. "paused"
        // must surface as playing=false so HUDs can show a ▶ overlay rather
        // than blanking the track entirely.
        let out = Media.parseScriptedResult(
            "Song\tArtist\tAlbum\t180000\t30\tpaused",
            bundleId: "com.spotify.client"
        )
        try expect(out != nil)
        try expectEqual(out!["title"]   as? String, "Song")
        try expectEqual(out!["playing"] as? Bool,   false)
    }

    test("parseScriptedResult: 6th-field playState=playing yields playing=true") {
        let out = Media.parseScriptedResult(
            "Song\tArtist\tAlbum\t180000\t30\tplaying",
            bundleId: "com.spotify.client"
        )
        try expect(out != nil)
        try expectEqual(out!["playing"] as? Bool, true)
    }

    test("parseScriptedResult: full Spotify row maps to media-channel keys") {
        // Spotify produces: title\tartist\talbum\tduration_ms\tposition_sec
        let out = Media.parseScriptedResult(
            "Stairway to Heaven\tLed Zeppelin\tIV\t482830\t127.5",
            bundleId: "com.spotify.client"
        )
        try expect(out != nil, "full row should parse")
        try expectEqual(out!["title"]    as? String, "Stairway to Heaven")
        try expectEqual(out!["artist"]   as? String, "Led Zeppelin")
        try expectEqual(out!["album"]    as? String, "IV")
        try expectEqual(out!["playing"]  as? Bool,   true)
        // Spotify durations are milliseconds; the parser normalizes to seconds
        // so the field matches MediaRemote's kMRMediaRemoteNowPlayingInfoDuration
        // (which is already in seconds). Stacks using duration/elapsed as a
        // progress fraction depend on the same units across sources.
        try expectEqual(out!["duration"] as? Double, 482.83)
        try expectEqual(out!["elapsed"]  as? Double, 127.5)
    }

    test("parseScriptedResult: blank artist/album fields are dropped, not empty-strung") {
        // AppleScript returns the literal "" when the metadata is missing;
        // dropping them keeps the JS-side `m.artist ? ... : ...` ternary in
        // bar/items/nowplaying.js producing "Title" instead of "Title · ".
        let out = Media.parseScriptedResult("OnlyTitle\t\t\t180000\t10",
                                            bundleId: "com.spotify.client")
        try expect(out != nil)
        try expectEqual(out!["title"] as? String, "OnlyTitle")
        try expect(out!["artist"] == nil, "blank artist should be dropped")
        try expect(out!["album"]  == nil, "blank album should be dropped")
        try expectEqual(out!["duration"] as? Double, 180.0)
    }

    test("parseScriptedResult: trailing newline from osascript is tolerated") {
        // osascript stdout always ends with \n. The parser trims so the
        // duration/elapsed fields parse as Double rather than failing on
        // a stray suffix that breaks Double(parts[N]).
        let out = Media.parseScriptedResult(
            "Song\tArtist\tAlbum\t1000\t0.5\n",
            bundleId: "com.spotify.client"
        )
        try expect(out != nil)
        try expectEqual(out!["duration"] as? Double, 1.0)
        try expectEqual(out!["elapsed"]  as? Double, 0.5)
    }

    test("parseScriptedResult: non-Spotify bundle skips duration/elapsed normalization") {
        // Other bundles may produce different units; until we add a per-app
        // normalizer the parser only emits duration/elapsed for known sources.
        let out = Media.parseScriptedResult(
            "Track\tArtist\tAlbum\t300\t30",
            bundleId: "com.unknown.app"
        )
        try expect(out != nil)
        try expectEqual(out!["title"]  as? String, "Track")
        try expectEqual(out!["artist"] as? String, "Artist")
        try expect(out!["duration"] == nil, "duration should be omitted for unknown bundles")
        try expect(out!["elapsed"]  == nil, "elapsed should be omitted for unknown bundles")
    }
}
