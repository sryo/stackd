import CoreBluetooth
import Foundation

// Tests for the read-only enumeration surface of Devices.swift. The file is
// dominated by IOKit / IOBluetooth / AVCapture / DiskArbitration plumbing —
// observers, notification ports, KVO watchers, DA sessions, one-shot
// AVCaptureSession grabbers. None of that is testable without driving real
// hardware lifecycle events (USB insert/remove, Bluetooth pairing churn,
// volume mount/unmount), so the unit tests stick to the static
// `snapshot()` / `list()` / `paired()` entry points that Bridge calls into
// to seed channels.
//
// Out of scope by design:
//   - USBObserver / CameraObserver / DisksHotplug — runloop-coupled
//     notification ports, KVO observer trees, DA sessions; covered by
//     integration reality, not unit tests.
//   - Camera.frame(...) against a real device — triggers TCC + opens a real
//     AVCaptureSession. Only the no-such-device bail path is exercised.
//   - Camera.describe / Camera.positionString / USB.describe /
//     Disks.describe — fileprivate; not on the testable surface.
//
// In scope:
//   - USB.snapshot()       → list-of-dicts shape contract (vendor/productID
//                            are required Ints; nullable strings are
//                            absent-or-non-empty, never present-and-empty).
//   - Bluetooth.paired()   → row shape (address string, connected Bool,
//                            optional classOfDevice Int, optional services
//                            array). Live call only when Bluetooth TCC is
//                            already granted to this context — an
//                            undetermined grant makes tccd abort the whole
//                            process, not deny (see bluetoothTCCGranted).
//   - Camera.snapshot()    → device enumeration + dict shape. Metadata-only;
//                            does NOT trigger Camera TCC.
//   - Disks.list()         → mountPoint is always present; nullable fields
//                            are absent-or-non-empty.
//
// Magnitudes (device counts, names, vendor IDs) depend on the host, so we
// never assert on them — only on the shape of whatever rows exist.

// Bundle.main reads the __info_plist section tests.sh embeds with -sectcreate,
// so this checks the built binary — not a file on disk.
private var hasBluetoothUsageDescription: Bool {
    Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
}

// Whether this process may reach IOBluetooth without tccd killing it. TCC
// attributes the access to the RESPONSIBLE process — the app that launched
// the shell, not this binary — so the embedded usage description above is
// not enough when the parent app (a terminal, an agent harness) lacks the
// key: tccd then SIGABRTs the suite instead of denying, even with the key
// embedded and visible to Bundle.main. CBCentralManager.authorization is a passive TCC read for the
// same kTCCServiceBluetoothAlways class: no prompt, no crash, any context.
// Only .allowedAlways is safe — .notDetermined means tccd would need to
// prompt, which is exactly the crash path; .denied yields [] and asserts
// nothing anyway.
private var bluetoothTCCGranted: Bool {
    CBCentralManager.authorization == .allowedAlways
}

func registerDevicesTests() {
    // MARK: - USB.snapshot

    test("USB.snapshot rows expose Int vendor/productID and omit empty name strings") {
        // Bridge's `usb` channel pushes these rows verbatim; JS consumers do
        // `.toString(16)` on the IDs. Name/serial keys are absent rather than
        // "" so `row.vendorName ?? row.productName` falls through correctly.
        for row in USB.snapshot() {
            try expect(row["vendorID"]  is Int, "vendorID should be Int, got \(type(of: row["vendorID"] ?? "nil"))")
            try expect(row["productID"] is Int, "productID should be Int, got \(type(of: row["productID"] ?? "nil"))")
            if let n = row["vendorName"]   as? String { try expect(!n.isEmpty, "empty vendorName leaked") }
            if let n = row["productName"]  as? String { try expect(!n.isEmpty, "empty productName leaked") }
            if let n = row["serialNumber"] as? String { try expect(!n.isEmpty, "empty serialNumber leaked") }
        }
    }

    // MARK: - Bluetooth.paired

    test("test binary embeds NSBluetoothAlwaysUsageDescription (TCC aborts without it)") {
        // Reaching IOBluetoothDevice without this key is not a denial — tccd
        // SIGABRTs the process mid-suite, and block-buffered output makes the
        // crash point look like whatever test a stdio flush boundary landed
        // on. tests.sh embeds Tests/Info.plist via -sectcreate __TEXT
        // __info_plist; this assertion turns a broken embed into one readable
        // failure. (The embed alone is still not launch-context-proof — see
        // bluetoothTCCGranted — but it is what makes properly-attributed
        // contexts prompt instead of crash.)
        try expect(hasBluetoothUsageDescription,
                   "NSBluetoothAlwaysUsageDescription missing from the embedded Info.plist — check the -sectcreate flags in tests.sh and Tests/Info.plist")
    }

    test("Sources/Info.plist declares NSBluetoothAlwaysUsageDescription (daemon dies without it)") {
        // The daemon embeds Sources/Info.plist the same way (build.sh
        // -sectcreate) and Bridge's bluetooth.paired sync calls the same
        // IOBluetooth API — dropping the key from the daemon plist turns the
        // first sd.devices bluetooth read into a daemon SIGABRT. Runs from
        // the repo root, same cwd contract as JSHarness reading Runtime/api.js.
        let data = try Data(contentsOf: URL(fileURLWithPath: "Sources/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let usage = (plist as? [String: Any])?["NSBluetoothAlwaysUsageDescription"]
        try expect(usage is String, "NSBluetoothAlwaysUsageDescription missing from Sources/Info.plist")
    }

    test("Bluetooth.paired rows carry address + connected; classOfDevice is absent rather than zero") {
        // Live coverage only where Bluetooth is already granted; everywhere
        // else this skips — see bluetoothTCCGranted for why calling anyway
        // can abort the suite. Stacks that bitmask classOfDevice assume the
        // key is absent rather than zero when there's no class info.
        guard bluetoothTCCGranted else { return }
        for row in Bluetooth.paired() {
            try expect(row["address"]   is String, "address should be String")
            try expect(row["connected"] is Bool,   "connected should be Bool")
            if let cod = row["classOfDevice"] {
                try expect(cod is Int, "classOfDevice should be Int, got \(type(of: cod))")
                try expect((cod as? Int) != 0, "classOfDevice present but zero (should have been omitted)")
            }
        }
    }

    // MARK: - Camera.snapshot / Camera.discover

    test("Camera.snapshot rows expose id/name/position/isInUse and omit empty manufacturer") {
        // Bridge's `camera` channel pushes these rows into stacks; position
        // is the documented enum-as-string ("front"/"back"/"unspecified")
        // that stacks switch on.
        let rows = Camera.snapshot()
        for row in rows {
            try expect(row["id"]       is String, "id should be String")
            try expect(row["name"]     is String, "name should be String")
            try expect(row["isInUse"]  is Bool,   "isInUse should be Bool")
            let pos = row["position"] as? String
            try expect(pos == "front" || pos == "back" || pos == "unspecified",
                       "position should be front/back/unspecified, got \(String(describing: pos))")
            // Same omit-when-empty contract as USB.
            if let mfr = row["manufacturer"] as? String {
                try expect(!mfr.isEmpty, "empty manufacturer leaked")
            }
        }
    }

    // MARK: - Disks.list

    test("Disks.list rows carry a non-empty mountPoint and correctly typed optional fields") {
        // mountPoint is the only stable identifier and is always written;
        // the rest are present only when the volume reports them.
        for row in Disks.list() {
            let mp = row["mountPoint"] as? String
            try expect(mp != nil && !mp!.isEmpty, "mountPoint should be a non-empty String: \(row)")
            if let v = row["name"]      { try expect(v is String, "name should be String") }
            if let v = row["fs"]        { try expect(v is String, "fs should be String") }
            if let v = row["removable"] { try expect(v is Bool,   "removable should be Bool") }
            if let v = row["ejectable"] { try expect(v is Bool,   "ejectable should be Bool") }
            if let v = row["size"]      { try expect(v is Int,    "size should be Int") }
            if let v = row["internal"]  { try expect(v is Bool,   "internal should be Bool") }
        }
    }

    test("Camera.frame: bogus deviceId bail completion is async AND does fire") {
        // Two asserts: completion must not fire INLINE (would re-enter
        // Bridge before the dispatch returned) AND it must eventually fire
        // (otherwise the fix dropped the completion entirely, which is a
        // different bug — the JS caller would hang forever waiting).
        var fired = false
        var arg: [String: Any]? = nil
        Camera.frame(deviceId: "not-a-real-camera-uniqueID-\(UUID().uuidString)") { result in
            fired = true
            arg = result
        }
        try expect(!fired, "Camera.frame completion must not fire synchronously on the bail path")
        // Spin the runloop so the DispatchQueue.main.async work item fires.
        let deadline = Date().addingTimeInterval(0.25)
        while !fired && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try expect(fired, "Camera.frame completion must fire within 250ms on bail path")
        try expect(arg == nil, "bail path delivers nil result (not crash)")
    }
}
