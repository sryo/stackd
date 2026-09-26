import Foundation
import AudioToolbox
import CoreAudio

// Shape contract for AudioProcesses.snapshot() — the data behind
// sd.audio.processes. Backed by CoreAudio's kAudioHardwareProperty
// ProcessObjectList (macOS 14.4+). Rows depend on what's running on the
// host, so only per-row structure is asserted; an empty list passes.
//
// Out of scope: "is this PID currently making sound?" (user state) and the
// observer/timer plumbing in Bridge.startAudioProcesses.

func registerAudioProcessesTests() {
    test("AudioProcesses.snapshot rows are well-formed: keys present, pid > 0, one row per pid/bundleId") {
        // pid=0 is CoreAudio's system sentinel with no controllable
        // equivalent. Helper processes collapse into their parent app's
        // bundleId, so neither a pid nor a resolved bundleId may repeat —
        // duplicates would render duplicate bar pills. bundleId and name
        // may be NSNull but the keys must exist.
        var pids = Set<Int>()
        var bundleIds = Set<String>()
        for row in AudioProcesses.snapshot() {
            guard let pid = row["pid"] as? Int else {
                throw Expectation(message: "pid must serialize as Int: \(row)")
            }
            try expect(pid > 0, "pid=\(pid) leaked; should have been filtered")
            try expect(!pids.contains(pid), "duplicate pid \(pid) in snapshot")
            pids.insert(pid)
            try expect(row["bundleId"] != nil, "bundleId key must exist (may be NSNull)")
            if let bid = row["bundleId"] as? String, !bid.isEmpty {
                try expect(!bundleIds.contains(bid), "duplicate bundleId \(bid) in snapshot")
                bundleIds.insert(bid)
            }
            try expect(row["name"] != nil, "name key must exist (may be NSNull)")
            try expect(row["playingOutput"] is Bool, "playingOutput must be Bool")
        }
    }
}
