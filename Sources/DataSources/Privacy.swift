import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit

// "Is anything capturing my screen / mic / camera right now?" — cross-
// references the live-capture signals macOS exposes through public APIs:
//
//  - camera     : AVCaptureDevice.isInUseByAnotherApplication (same signal
//                 the sd.camera channel already uses, but filtered to the
//                 in-use subset and reshaped).
//  - microphone : CoreAudio's kAudioDevicePropertyDeviceIsRunningSomewhere
//                 on each input device. True iff some process anywhere on
//                 the system is currently reading from that device — same
//                 thing that drives the orange dot in Control Center, just
//                 surfaced per-device instead of as a single global flag.
//  - screen     : v1 always returns []. Process-attributing the system's
//                 screen-recording indicator requires private SPI
//                 (CGSCopyManagedDisplaySpacesForCaptureClient et al) or
//                 a TCC.db read (needs Full Disk Access). Both are out of
//                 scope for v1. The shape is preserved so JS consumers
//                 don't have to special-case the missing field; future v2
//                 can populate the array without changing the contract.
//
// Process attribution (which APP is using the camera / mic) is also a v1
// cut for the same reason — `lsof | grep VDC` or open-file-descriptor walks
// against /dev/* are fragile and would only surface raw PIDs anyway.
// v1 returns `[{ device, inUse }]` per-device. v2 may add `[{ app, pid }]`
// once a stable signal exists.
//
// This is a polled primitive: the underlying APIs have no broadcast hook
// for "anybody started recording", so PrivacyObserver runs a 2s timer and
// diff-pushes via startChannel's lastState dedupe. 2s matches the cadence
// of the orange/green dots in Control Center themselves.

enum Privacy {
    /// One-shot snapshot. Always returns the three-key dict shape — empty
    /// arrays where nothing's active. The JS surface returns this directly
    /// from `sd.privacy.recording()`.
    static func recording() -> [String: Any] {
        return [
            "screen":     screenSnapshot(),
            "camera":     cameraSnapshot(),
            "microphone": microphoneSnapshot()
        ]
    }

    /// v1: always []. See file-level note for the SPI rationale.
    /// Returns `[[String: Any]]` (not `[String]` / nil) so the shape stays
    /// stable across versions — a v2 that populates this won't break any
    /// caller that's already destructuring `entry.app` / `entry.pid`.
    static func screenSnapshot() -> [[String: Any]] {
        return []
    }

    /// Walks AVCaptureDevice.discover() (same enumeration the sd.camera
    /// channel uses) and filters to devices currently in use by another
    /// application. Returns one entry per in-use camera:
    ///   [{ device: "<localizedName>", inUse: true, id: "<uniqueID>" }]
    /// Empty when nothing's recording — that's the common case.
    /// v1 cut: no `app` / `pid` keys. AVCaptureDevice doesn't expose the
    /// owning process; resolving it would require sandbox-fragile lsof
    /// walks (see file-level note).
    static func cameraSnapshot() -> [[String: Any]] {
        return Camera.discover()
            .filter { $0.isInUseByAnotherApplication }
            .map { device in
                [
                    "device": device.localizedName,
                    "id":     device.uniqueID,
                    "inUse":  true
                ]
            }
    }

    /// Walks every CoreAudio device that has at least one input stream and
    /// returns the subset where `kAudioDevicePropertyDeviceIsRunningSomewhere`
    /// is true. That property flips on the moment any process starts an
    /// input stream against the device and back off when the last stream
    /// closes — same signal that drives Control Center's orange dot, just
    /// surfaced per-device. Reading the property does NOT open an input
    /// stream, so this is microphone-TCC-free.
    /// v1 cut: no `app` / `pid` keys (same rationale as camera).
    static func microphoneSnapshot() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for id in inputDeviceIDs() {
            guard isRunningSomewhere(deviceId: id) else { continue }
            out.append([
                "device": Audio.name(of: id) ?? "Unknown",
                "id":     Int(id),
                "inUse":  true
            ])
        }
        return out
    }

    // MARK: - CoreAudio plumbing

    /// Enumerate every audio device that has at least one input stream.
    /// Equivalent to `Audio.devices(scope: .input)` but returns raw
    /// AudioDeviceIDs without the descriptive payload (we only need the
    /// id to check the running-somewhere property).
    private static func inputDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                &dataSize, &ids) == noErr else { return [] }

        // Filter to devices that actually have at least one input stream
        // (output-only devices report DeviceIsRunningSomewhere for their
        // output side; without this filter we'd surface the speaker
        // playing music as a "microphone in use" false positive).
        return ids.filter { hasInputStreams(deviceId: $0) }
    }

    /// True iff the device has at least one stream on the input scope.
    /// Mirrors Audio.hasStreams but inlined here to avoid widening that
    /// file's API surface for one extra caller.
    private static func hasInputStreams(deviceId: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceId, &addr, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    /// True iff some process (this one or another) currently has an input
    /// stream open against the device. The "Somewhere" variant is system-
    /// wide; the (non-Somewhere) `kAudioDevicePropertyDeviceIsRunning` only
    /// reflects our own process's usage and would miss every other app.
    private static func isRunningSomewhere(deviceId: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(deviceId, &addr) else { return false }
        let err = AudioObjectGetPropertyData(deviceId, &addr, 0, nil, &size, &value)
        return err == noErr && value != 0
    }

    // MARK: - Pure helpers (testable)

    /// Diff two snapshots. True when the set of active recorders differs
    /// between `old` and `new`. Used by the observer to skip pushing a
    /// channel update when nothing's actually changed — saves the WebKit
    /// roundtrip on the steady-state (nothing recording) common case.
    ///
    /// "Differs" means: any of the three category arrays has a different
    /// count, OR (same count, different membership). Comparison is by the
    /// `id` field within each entry — order is not significant (CoreAudio
    /// + AVCaptureDevice both enumerate in implementation-defined order
    /// that can shift mid-session when devices reconnect).
    ///
    /// Pure helper, no IO. Pulled out for direct test coverage of the
    /// dedupe logic — the live snapshot/observer path is impure and not
    /// unit-testable; the diff logic is the actual bug surface for
    /// "channel fires too often" / "channel doesn't fire when it should".
    static func hasChanged(old: [String: Any], new: [String: Any]) -> Bool {
        for category in ["screen", "camera", "microphone"] {
            let oldList = (old[category] as? [[String: Any]]) ?? []
            let newList = (new[category] as? [[String: Any]]) ?? []
            if oldList.count != newList.count { return true }
            let oldIds = Set(oldList.compactMap { idString($0["id"]) })
            let newIds = Set(newList.compactMap { idString($0["id"]) })
            if oldIds != newIds { return true }
        }
        return false
    }

    /// Coerce the heterogeneous `id` field (camera = String uniqueID,
    /// microphone = Int AudioDeviceID) into a comparable string. Returns
    /// nil when the value isn't representable — those entries are dropped
    /// from the diff set, which is conservative (a malformed entry won't
    /// suppress a real change).
    private static func idString(_ raw: Any?) -> String? {
        if let s = raw as? String { return "s:" + s }
        if let i = raw as? Int    { return "i:\(i)" }
        return nil
    }
}

// MARK: - Observer

/// 2s polled observer. Same cadence as Sensors / Host — the orange/green
/// dots in Control Center themselves update at roughly this rate, so
/// matching keeps the UX consistent. startChannel's lastState dedupe
/// suppresses the steady-state "nothing recording" repeats, and
/// Privacy.hasChanged drives the same dedupe for the in-use case.
///
/// No native broadcast hook exists for "anybody started recording" — the
/// AVCaptureDevice KVO surface only fires when WE open a stream; CoreAudio
/// has no system-wide "input started" notification. Polling is unavoidable.
/// Per-stack fanout can be slowed further via
/// `sd.channel.setInterval("privacy", 5000)`.
final class PrivacyObserver: RefCountedObserver {
    static let shared = PrivacyObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Lazy fire: snapshot is usually empty (nothing recording). Hash
            // the JSON-stable form and skip the per-stack push when the
            // state is unchanged. Sorted-keys ensures dict ordering doesn't
            // produce spurious diffs.
            let snap = Privacy.recording()
            if let data = try? JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys]) {
                self.fireIfChanged("privacy", hash: data.hashValue)
            } else {
                self.fire()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        return Token { t.invalidate() }
    }
}
