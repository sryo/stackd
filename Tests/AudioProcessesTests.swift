import Foundation
import AudioToolbox
import CoreAudio

// Shape contract for AudioProcesses.snapshot() — the data behind
// sd.audio.processes. Backed by CoreAudio's kAudioHardwareProperty
// ProcessObjectList (macOS 14.4+). Tests assert dict structure only;
// real PIDs/bundleIds depend on what's running on the host at test time,
// so per-row values aren't checked.
//
// Out of scope:
//   - "is this PID currently making sound?" — depends on user state.
//   - The observer/timer plumbing in Bridge.startAudioProcesses — covered
//     by integration reality (poll → push → JS subscribe).

func registerAudioProcessesTests() {

    test("AudioProcesses.snapshot returns an array") {
        // No assumptions about count. A freshly-booted Mac may have very
        // few audio-producing processes; the call must still return [] or
        // a list, not throw or hang.
        let snap = AudioProcesses.snapshot()
        try expect(snap is [[String: Any]], "snapshot must be array of dicts")
    }

    test("AudioProcesses.snapshot entries have the required keys") {
        let snap = AudioProcesses.snapshot()
        // Skip the body if no audio processes exist right now (rare but
        // possible). Shape contract is per-entry; nothing to assert if
        // the list is empty.
        guard let first = snap.first else { return }
        // PID must be present and an Int — JS reads this as a number.
        try expect(first["pid"] != nil, "pid key must exist")
        try expect(first["pid"] is Int, "pid must serialize as Int")
        // bundleId is nullable (system processes without a bundle exist,
        // e.g. coreaudiod itself if it surfaced). NSNull encodes as null
        // on the JS side. Either a non-empty String or NSNull is acceptable.
        try expect(first["bundleId"] != nil, "bundleId key must exist (may be NSNull)")
        // name is human-friendly fallback when bundleId fails to resolve.
        try expect(first["name"] != nil, "name key must exist (may be NSNull)")
        // playingOutput is the live "making sound right now" bit. UInt32
        // from CoreAudio (1=running, 0=silent); we surface as Bool to JS.
        try expect(first["playingOutput"] is Bool, "playingOutput must be Bool")
    }

    test("AudioProcesses.snapshot only emits non-zero PIDs") {
        // CoreAudio's process-object list can include a sentinel with
        // pid=0 representing the system itself. We filter it so JS never
        // sees a row that doesn't correspond to a real running app — a
        // pid=0 row would never have a controllable equivalent.
        let snap = AudioProcesses.snapshot()
        for row in snap {
            if let pid = row["pid"] as? Int {
                try expect(pid > 0, "pid=\(pid) leaked; should have been filtered")
            }
        }
    }

    test("AudioProcesses.snapshot dedupes by PID") {
        // The process object list contains one AudioObjectID per process.
        // Two AudioObjectIDs ever resolving to the same PID would create
        // duplicate bar pills — guard against that even though it's not
        // expected from CoreAudio in normal operation.
        let snap = AudioProcesses.snapshot()
        var pids = Set<Int>()
        for row in snap {
            guard let pid = row["pid"] as? Int else { continue }
            try expect(!pids.contains(pid), "duplicate pid \(pid) in snapshot")
            pids.insert(pid)
        }
    }
}
