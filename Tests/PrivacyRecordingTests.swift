import Foundation

// Tests for `Sources/DataSources/Privacy.swift`.
//
// recording() reads live AVCaptureDevice / CoreAudio state (enumeration and
// in-use flags only — no capture session, so no TCC prompt); only its shape
// is deterministic. PrivacyObserver polls that snapshot, so its
// subscriber-gating is what keeps the poll off the CPU while no stack
// subscribes.

func registerPrivacyRecordingTests() {
    test("recording() returns screen/camera/microphone as arrays of entries") {
        let r = Privacy.recording()
        try expect(r["screen"]     is [[String: Any]], "'screen' must be [[String: Any]]")
        try expect(r["camera"]     is [[String: Any]], "'camera' must be [[String: Any]]")
        try expect(r["microphone"] is [[String: Any]], "'microphone' must be [[String: Any]]")
        // Usually empty; when something is recording, each entry names the
        // device and is flagged in use.
        for key in ["camera", "microphone"] {
            for entry in (r[key] as? [[String: Any]]) ?? [] {
                try expect(entry["device"] is String, "\(key) entry needs a device name")
                try expectEqual(entry["inUse"] as? Bool, true, "\(key) entry inUse")
            }
        }
    }

    test("PrivacyObserver: inactive until subscribed, active while subscribed, torn down after debounce") {
        try expect(!PrivacyObserver.shared.isActive,
                   "PrivacyObserver must not be active before any stack subscribes")
        let token = PrivacyObserver.shared.subscribe { }
        try expect(PrivacyObserver.shared.isActive)
        token.cancel()
        spin(timeout: 5.2) { !PrivacyObserver.shared.isActive }
        try expect(!PrivacyObserver.shared.isActive,
                   "PrivacyObserver must deactivate ≤5.2s after last unsubscribe")
    }
}
