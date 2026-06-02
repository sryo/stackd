import Foundation

// Tests for the read-only enumeration surface of Devices.swift. The file is
// dominated by IOKit / IOBluetooth / AVCapture / DiskArbitration plumbing —
// observers, notification ports, KVO watchers, DA sessions, one-shot
// AVCaptureSession grabbers. None of that is testable without driving real
// hardware lifecycle events (USB insert/remove, Bluetooth pairing churn,
// volume mount/unmount), so the unit tests stick to the four static
// `snapshot()` / `list()` / `paired()` / `discover()` entry points that
// Bridge calls into to seed channels.
//
// Out of scope by design:
//   - USBObserver / CameraObserver / DisksHotplug — runloop-coupled
//     notification ports, KVO observer trees, DA sessions; covered by
//     integration reality, not unit tests.
//   - Camera.frame(...) — triggers TCC + opens a real AVCaptureSession.
//     A unit test that asks for a frame would block on the camera prompt
//     and burn the timeout.
//   - Camera.describe / Camera.positionString / USB.describe /
//     Disks.describe — fileprivate; not on the testable surface.
//
// In scope:
//   - USB.snapshot()       → list-of-dicts shape contract (vendor/productID
//                            are required Ints; nullable strings are
//                            absent-or-non-empty, never present-and-empty).
//   - Bluetooth.paired()   → row shape (address string, connected Bool,
//                            optional classOfDevice Int, optional services
//                            array). Triggers Bluetooth TCC the first time;
//                            denial yields [] which still satisfies the
//                            shape contract.
//   - Camera.snapshot() /
//     Camera.discover()    → device enumeration + dict shape. Metadata-only;
//                            does NOT trigger Camera TCC.
//   - Disks.list()         → mountPoint is always present; nullable fields
//                            are absent-or-non-empty.
//
// These are tracer-bullet tests: every method that Bridge dispatches into
// has at least one shape assertion. Magnitudes (device counts, names,
// vendor IDs) depend on the host, so we never assert on them.

func registerDevicesTests() {
    // MARK: - USB.snapshot

    test("USB.snapshot returns a list whose rows expose vendorID + productID as Int") {
        // Bridge's `usb` channel pushes these rows verbatim into stacks;
        // vendor/productID being Int (not NSNumber, not String) is the load-
        // bearing contract — JS consumers do `.toString(16)` on them to
        // produce 4-digit hex displays.
        let rows = USB.snapshot()
        for row in rows {
            try expect(row["vendorID"]  is Int, "vendorID should be Int, got \(type(of: row["vendorID"] ?? "nil"))")
            try expect(row["productID"] is Int, "productID should be Int, got \(type(of: row["productID"] ?? "nil"))")
        }
    }

    test("USB.snapshot omits empty vendor/product/serial strings instead of emitting them") {
        // describe(device:) checks !n.isEmpty before adding name keys — a
        // regression that emitted "" would break stacks that test
        // `row.vendorName ?? row.productName` (both branches truthy).
        let rows = USB.snapshot()
        for row in rows {
            if let n = row["vendorName"]   as? String { try expect(!n.isEmpty, "empty vendorName leaked") }
            if let n = row["productName"]  as? String { try expect(!n.isEmpty, "empty productName leaked") }
            if let n = row["serialNumber"] as? String { try expect(!n.isEmpty, "empty serialNumber leaked") }
        }
    }

    test("USB.snapshot is stable across back-to-back reads") {
        // Walking the IORegistry should be deterministic over a stable
        // hardware state. Catches a class of "first call seeds, second
        // call sees fewer" regressions in the iterator drain logic.
        let a = USB.snapshot()
        let b = USB.snapshot()
        try expectEqual(a.count, b.count)
    }

    // MARK: - Bluetooth.paired

    test("Bluetooth.paired returns rows with required address + connected keys") {
        // The first call triggers the Bluetooth TCC prompt on macOS 11+.
        // Denial → []; permitted + no paired devices → []; permitted +
        // paired devices → populated. All three states satisfy the shape
        // contract: any row that DOES exist must carry the required keys.
        let rows = Bluetooth.paired()
        for row in rows {
            try expect(row["address"]   is String, "address should be String")
            try expect(row["connected"] is Bool,   "connected should be Bool")
        }
    }

    test("Bluetooth.paired classOfDevice (when present) is Int and non-zero") {
        // describe(_:) only emits classOfDevice if cod != 0 — stacks that
        // bitmask the packed 24-bit field assume the key is absent rather
        // than zero, so they don't false-positive on "no class info."
        let rows = Bluetooth.paired()
        for row in rows {
            if let cod = row["classOfDevice"] {
                try expect(cod is Int, "classOfDevice should be Int, got \(type(of: cod))")
                try expect((cod as? Int) != 0, "classOfDevice present but zero (should have been omitted)")
            }
        }
    }

    // MARK: - Camera.snapshot / Camera.discover

    test("Camera.discover and Camera.snapshot agree on device count") {
        // snapshot() is `discover().map(describe)` — counts must match or
        // describe silently dropped a device.
        let discovered = Camera.discover()
        let snapped    = Camera.snapshot()
        try expectEqual(discovered.count, snapped.count)
    }

    test("Camera.snapshot rows expose id/name/position/isInUse with the right types") {
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
        }
    }

    test("Camera.snapshot omits empty manufacturer strings instead of emitting them") {
        // Same omit-when-empty contract as USB — stacks rely on
        // `row.manufacturer != null` meaning "has a real value."
        let rows = Camera.snapshot()
        for row in rows {
            if let mfr = row["manufacturer"] as? String {
                try expect(!mfr.isEmpty, "empty manufacturer leaked")
            }
        }
    }

    // MARK: - Disks.list

    test("Disks.list rows always carry mountPoint as a String") {
        // mountPoint is the only stable identifier — describe(mountPoint:)
        // unconditionally writes it before any optional fields. Bridge's
        // `disks.list` permission-gated sync exposes this verbatim.
        let rows = Disks.list()
        for row in rows {
            try expect(row["mountPoint"] is String, "mountPoint should be String")
            try expect(!((row["mountPoint"] as? String) ?? "").isEmpty,
                       "mountPoint should be non-empty")
        }
    }

    test("Disks.list optional fields land with the right types when present") {
        // Stacks pattern-match on these types for "is this an ejectable
        // removable" → eject prompt, "is this internal" → omit from UI.
        let rows = Disks.list()
        for row in rows {
            if let v = row["name"]      { try expect(v is String, "name should be String") }
            if let v = row["fs"]        { try expect(v is String, "fs should be String") }
            if let v = row["removable"] { try expect(v is Bool,   "removable should be Bool") }
            if let v = row["ejectable"] { try expect(v is Bool,   "ejectable should be Bool") }
            if let v = row["size"]      { try expect(v is Int,    "size should be Int") }
            if let v = row["internal"]  { try expect(v is Bool,   "internal should be Bool") }
        }
    }
}
