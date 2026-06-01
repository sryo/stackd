import Foundation

// Tests for the pure helpers in `Privacy` — the imperative
// recording()/cameraSnapshot()/microphoneSnapshot() paths can't be
// unit-tested in isolation (they hit live AVCaptureDevice +
// CoreAudio + depend on whatever's running on the host machine),
// but the diff helper (`hasChanged`) and the shape contract are
// pure and form the actual bug surface for JS callers.
//
// CLAUDE.md: "you can't test everything — focus on critical paths."
// The critical path here is the dedupe: a buggy `hasChanged` either
// fires the privacy channel on every poll (waste) or never fires
// when something starts/stops recording (silent broken contract).
// Pinning the diff logic catches both regressions before they hit
// production. Shape contract for `screenSnapshot()` is also pinned
// — JS consumers will start destructuring `entry.app` / `entry.pid`
// once v2 ships, so the v1 "always empty array" promise needs to
// stay honest.

func registerPrivacyRecordingTests() {
    test("recording() returns the three required category keys") {
        let r = Privacy.recording()
        try expect(r["screen"]     != nil, "missing 'screen' key")
        try expect(r["camera"]     != nil, "missing 'camera' key")
        try expect(r["microphone"] != nil, "missing 'microphone' key")
        // Each is an array (possibly empty) — never nil, never a dict.
        try expect(r["screen"]     is [[String: Any]], "'screen' must be [[String: Any]]")
        try expect(r["camera"]     is [[String: Any]], "'camera' must be [[String: Any]]")
        try expect(r["microphone"] is [[String: Any]], "'microphone' must be [[String: Any]]")
    }

    test("screenSnapshot() always returns empty array in v1") {
        // v1 contract: process attribution for screen capture needs
        // private SPI; the public API path returns []. v2 can fill this
        // in without breaking any caller that relied on the array shape.
        // If a future change starts populating this, BOTH the call site
        // and the README/api.js docstring need updating in the same PR.
        let s = Privacy.screenSnapshot()
        try expectEqual(s.count, 0)
    }

    test("hasChanged returns false for identical empty snapshots") {
        let empty: [String: Any] = [
            "screen":     [[String: Any]](),
            "camera":     [[String: Any]](),
            "microphone": [[String: Any]]()
        ]
        try expect(!Privacy.hasChanged(old: empty, new: empty),
                   "empty == empty should NOT report change")
    }

    test("hasChanged returns true when a camera starts recording") {
        let before: [String: Any] = [
            "screen":     [[String: Any]](),
            "camera":     [[String: Any]](),
            "microphone": [[String: Any]]()
        ]
        let after: [String: Any] = [
            "screen": [[String: Any]](),
            "camera": [["device": "FaceTime HD",
                        "id":     "0x12345",
                        "inUse":  true]],
            "microphone": [[String: Any]]()
        ]
        try expect(Privacy.hasChanged(old: before, new: after),
                   "camera 0 → 1 should report change")
    }

    test("hasChanged returns true when a microphone stops recording") {
        let before: [String: Any] = [
            "screen": [[String: Any]](),
            "camera": [[String: Any]](),
            "microphone": [["device": "MacBook Pro Microphone",
                            "id":     42,
                            "inUse":  true]]
        ]
        let after: [String: Any] = [
            "screen":     [[String: Any]](),
            "camera":     [[String: Any]](),
            "microphone": [[String: Any]]()
        ]
        try expect(Privacy.hasChanged(old: before, new: after),
                   "microphone 1 → 0 should report change")
    }

    test("hasChanged returns false when same devices in different order") {
        // CoreAudio + AVCaptureDevice enumerate in implementation-defined
        // order that can shift mid-session when devices reconnect. The
        // diff is set-based (by `id`), so a reorder of the same membership
        // must NOT fire the channel.
        let snap1: [String: Any] = [
            "screen":     [[String: Any]](),
            "camera":     [[String: Any]](),
            "microphone": [
                ["device": "Built-in", "id": 1, "inUse": true],
                ["device": "USB Mic",  "id": 2, "inUse": true]
            ]
        ]
        let snap2: [String: Any] = [
            "screen":     [[String: Any]](),
            "camera":     [[String: Any]](),
            "microphone": [
                ["device": "USB Mic",  "id": 2, "inUse": true],
                ["device": "Built-in", "id": 1, "inUse": true]
            ]
        ]
        try expect(!Privacy.hasChanged(old: snap1, new: snap2),
                   "reordered same-membership snapshots should NOT report change")
    }

    test("hasChanged returns true when one device swaps for another at the same count") {
        // Common case: user yanks one mic, plugs in another mid-call. Count
        // stays at 1, but the active device id changed — must fire so JS
        // can re-render "X is recording" → "Y is recording".
        let snap1: [String: Any] = [
            "screen":     [[String: Any]](),
            "camera":     [[String: Any]](),
            "microphone": [["device": "Built-in", "id": 1, "inUse": true]]
        ]
        let snap2: [String: Any] = [
            "screen":     [[String: Any]](),
            "camera":     [[String: Any]](),
            "microphone": [["device": "USB Mic",  "id": 2, "inUse": true]]
        ]
        try expect(Privacy.hasChanged(old: snap1, new: snap2),
                   "device swap at same count should report change")
    }

    test("hasChanged tolerates missing category keys (degrades to empty)") {
        // Defensive: if a future code path forgets a key, the diff should
        // treat the missing slot as empty rather than crash. Matches the
        // shape-validation conservativism elsewhere in the codebase
        // (Bridge.jsonify, ChannelInference) — never throw on malformed
        // input, always return a sensible default.
        let partial: [String: Any] = ["camera": [[String: Any]]()]
        let empty:   [String: Any] = [:]
        try expect(!Privacy.hasChanged(old: partial, new: empty),
                   "missing keys should be treated as empty arrays")
    }
}
