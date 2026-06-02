import Foundation
import IOKit.pwr_mgt

// Characterization tests for the non-diskIO surface of Sources/DataSources/Sensors.swift.
//
// Covered enums:
//   - Sensors  (HID thermal/voltage/current/fan snapshot shape)
//   - Battery  (IOPS + AppleSmartBattery readers; shape + sentinel handling)
//   - Host     (info() + loadSnapshot() — NOT diskIO/computeRate, those live in HostDiskIOTests)
//   - Caffeinate (snapshot shape + assert() argument validation + release() idempotency)
//
// We deliberately do NOT call `Caffeinate.assert(type:"system", ...)` with a valid
// type — that would mint a real IOPM assertion and keep the box awake until the
// process exits. The unknown-type path is safe to exercise (returns nil with no
// IOKit side effect), and release() with kIOPMNullAssertionID is the documented
// no-op contract.

func registerSensorsTests() {
    // MARK: - Sensors.snapshot()

    test("Sensors.snapshot returns the four documented parallel arrays") {
        // Contract from the doc comment: temperatures / voltages / currents / fans.
        // Empty arrays are allowed on Intel or when SPI returns no matches —
        // the keys themselves must always be present so Bridge can push the
        // channel without conditional shape branches on the JS side.
        let snap = Sensors.snapshot()
        try expect(snap["temperatures"] is [[String: Any]], "temperatures must be [[String: Any]]")
        try expect(snap["voltages"]     is [[String: Any]], "voltages must be [[String: Any]]")
        try expect(snap["currents"]     is [[String: Any]], "currents must be [[String: Any]]")
        try expect(snap["fans"]         is [[String: Any]], "fans must be [[String: Any]]")
    }

    test("Sensors.snapshot temperature entries carry name + finite value + °C unit") {
        // Apple silicon exposes 40+ thermal probes; if any are present, each
        // entry must satisfy the documented dictionary shape. Intel boxes
        // legitimately yield an empty array — skip the check there.
        let snap = Sensors.snapshot()
        guard let temps = snap["temperatures"] as? [[String: Any]], !temps.isEmpty else {
            return  // Intel / no matches — nothing to characterize.
        }
        for entry in temps {
            try expect(entry["name"] is String, "temperature name must be String")
            guard let v = entry["value"] as? Double else {
                throw Expectation(message: "temperature value must be Double, got \(String(describing: entry["value"]))")
            }
            try expect(v.isFinite, "temperature value must be finite (NaN/Inf are filtered)")
            try expectEqual(entry["unit"] as? String, "°C")
        }
    }

    test("Sensors.snapshot fan entries expose integer RPM when present") {
        // Fanless Macs return [] — that's fine. When fans are reported, RPM
        // must be a positive Int (the queryFans branch drops rpm <= 0).
        let snap = Sensors.snapshot()
        guard let fans = snap["fans"] as? [[String: Any]], !fans.isEmpty else {
            return  // Fanless or no matches.
        }
        for entry in fans {
            try expect(entry["name"] is String, "fan name must be String")
            guard let rpm = entry["rpm"] as? Int else {
                throw Expectation(message: "fan rpm must be Int, got \(String(describing: entry["rpm"]))")
            }
            try expect(rpm > 0, "fan rpm must be > 0 (zero/negative are filtered)")
        }
    }

    // MARK: - Battery

    test("Battery.percent returns -1 or a 0...100 value") {
        // -1 sentinel = no battery present (desktops). Real laptops surface a
        // bounded percentage. Anything outside this range means the IOPS dict
        // shape changed and the round() math drifted.
        let p = Battery.percent()
        try expect(p == -1 || (p >= 0 && p <= 100), "percent out of range: \(p)")
    }

    test("Battery.timeRemaining never leaks the IOPS -1 sentinel") {
        // The doc comment commits to surfacing nil instead of the
        // kIOPSTimeRemainingUnknown (-1) sentinel from IOPS. Any non-nil
        // result must be a non-negative minute count.
        if let m = Battery.timeRemaining() {
            try expect(m >= 0, "timeRemaining should be nil or >= 0, got \(m)")
        }
    }

    test("Battery readers never crash on desktops (nil-tolerant)") {
        // Each Battery field has a graceful nil/zero path when no battery is
        // present. Calling all of them in sequence must not throw or trap —
        // this is the contract Bridge relies on when assembling the snapshot
        // dict on a Mac mini / Studio.
        _ = Battery.percent()
        _ = Battery.isCharging()
        _ = Battery.timeRemaining()
        _ = Battery.isFinishingCharge()
        _ = Battery.currentCapacity()
        _ = Battery.maxCapacity()
        _ = Battery.designCapacity()
        _ = Battery.health()
        _ = Battery.cycles()
        _ = Battery.amperage()
        _ = Battery.voltage()
        // Reaching this line is the assertion.
        try expect(true)
    }

    // MARK: - Host.info() (one-shot, constant-for-process-life)

    test("Host.info exposes hostname/os/arch/cpuCount/ramMB with sane types") {
        let info = Host.info()
        try expect(info["hostname"] is String, "hostname must be String")
        try expect(info["locale"] is String,   "locale must be String")
        try expect(info["arch"] is String,     "arch must be String")
        guard let cpu = info["cpuCount"] as? Int else {
            throw Expectation(message: "cpuCount must be Int, got \(String(describing: info["cpuCount"]))")
        }
        try expect(cpu > 0, "cpuCount must be > 0")
        guard let ram = info["ramMB"] as? Int else {
            throw Expectation(message: "ramMB must be Int, got \(String(describing: info["ramMB"]))")
        }
        try expect(ram > 0, "ramMB must be > 0")
        // Nested os dict: name=macOS + version + build keys.
        guard let os = info["os"] as? [String: Any] else {
            throw Expectation(message: "os must be [String: Any]")
        }
        try expectEqual(os["name"] as? String, "macOS")
        try expect(os["version"] is String, "os.version must be String")
        try expect(os["build"]   is String, "os.build must be String")
    }

    // MARK: - Host.loadSnapshot() (cpu diff + idle + memory)

    test("Host.loadSnapshot first call returns nil, second call yields cpu fractions") {
        // Documented contract: cpuFractions() needs a prior tick to diff
        // against, so the first call seeds lastCpuTicks and returns nil.
        // The second call (after a brief delay so dTotal > 0) returns the
        // real snapshot. We don't reset the static lastCpuTicks here — if
        // other tests already primed it, the first call may already be
        // non-nil; that's fine, we only need to verify that a snapshot is
        // eventually obtainable and well-shaped.
        _ = Host.loadSnapshot()
        // Burn a few ticks so CPU counters move forward.
        Thread.sleep(forTimeInterval: 0.05)
        guard let snap = Host.loadSnapshot() else {
            // Extremely unlucky timing — try once more.
            Thread.sleep(forTimeInterval: 0.05)
            guard let retry = Host.loadSnapshot() else {
                throw Expectation(message: "loadSnapshot returned nil twice in a row")
            }
            try expect(retry["cpu"] is [String: Double], "cpu must be [String: Double]")
            return
        }
        guard let cpu = snap["cpu"] as? [String: Double] else {
            throw Expectation(message: "cpu must be [String: Double], got \(String(describing: snap["cpu"]))")
        }
        // Four documented fractions, each in [0, 1] modulo the round3 jitter.
        for key in ["user", "system", "idle", "total"] {
            guard let v = cpu[key] else {
                throw Expectation(message: "cpu.\(key) missing")
            }
            try expect(v >= 0 && v <= 1.001, "cpu.\(key) out of [0,1], got \(v)")
        }
        // idleSeconds always present, always non-negative.
        guard let idle = snap["idleSeconds"] as? Double else {
            throw Expectation(message: "idleSeconds must be Double")
        }
        try expect(idle >= 0, "idleSeconds must be >= 0, got \(idle)")
    }

    test("Host.loadSnapshot memoryPressure is one of normal/warning/critical when present") {
        // Optional field; may be absent on rare sysctl failures. When present
        // it must match the documented three-value enum.
        // Prime cpu diff so we get a non-nil snapshot.
        _ = Host.loadSnapshot()
        Thread.sleep(forTimeInterval: 0.05)
        guard let snap = Host.loadSnapshot() else { return }
        if let pressure = snap["memoryPressure"] as? String {
            try expect(["normal", "warning", "critical"].contains(pressure),
                       "unexpected memoryPressure value: \(pressure)")
        }
    }

    // MARK: - Caffeinate

    test("Caffeinate.snapshot exposes sleeping + locked booleans") {
        // Bridge pushes this dict at signal-install time. Both flags must be
        // bool-typed regardless of observer install state — the enum reads
        // off CaffeinateObserver.shared which is initialized lazily.
        let snap = Caffeinate.snapshot()
        try expect(snap["sleeping"] is Bool, "sleeping must be Bool")
        try expect(snap["locked"]   is Bool, "locked must be Bool")
    }

    test("Caffeinate.assert returns nil for an unknown assertion type") {
        // Defensive branch: anything outside display/system/userActivity
        // logs to stderr and returns nil — no IOPM assertion is created, so
        // this is safe to exercise without mutating system sleep policy.
        let id = Caffeinate.assert(type: "definitely-not-a-real-type", reason: "test")
        try expect(id == nil, "unknown type should yield nil, got \(String(describing: id))")
    }

    test("Caffeinate.release on the null assertion id is a no-op returning false") {
        // Documented contract: no-op on kIOPMNullAssertionID. Guards Bridge
        // from double-release crashes when a scope drain runs after an
        // explicit release.
        let result = Caffeinate.release(id: IOPMAssertionID(kIOPMNullAssertionID))
        try expectEqual(result, false)
    }

    // MARK: - SensorsObserver subscriber-gating
    //
    // 2026-06-02 (lazy-fire refactor): SensorsObserver now JSON-encodes
    // its snapshot to compute a dedup hash on every 2s tick. The gating
    // contract keeps that work off the CPU when no stack subscribes.

    test("SensorsObserver: inactive at startup") {
        try expect(!SensorsObserver.shared.isActive,
                   "SensorsObserver must not be active before any stack subscribes")
    }

    test("SensorsObserver: activates on subscribe, deactivates after debounce") {
        let token = SensorsObserver.shared.subscribe { }
        try expect(SensorsObserver.shared.isActive)
        token.cancel()
        let deadline = Date().addingTimeInterval(5.2)
        while SensorsObserver.shared.isActive && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        try expect(!SensorsObserver.shared.isActive,
                   "SensorsObserver must deactivate ≤5.2s after last unsubscribe")
    }
}
