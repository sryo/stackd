import Foundation
import IOKit
import IOKit.ps

/// Fires whenever IOKit reports a power-source change — plug/unplug, capacity
/// step, source list change. Replaces the 30s `batteryTimer` poll in Bridge.
/// Lazy: the IOKit runloop source is only installed while at least one stack
/// subscribes; teardown after a 5s debounce when the last unsubscribes.
final class BatteryObserver: RefCountedObserver {
    static let shared = BatteryObserver()
    private override init() { super.init() }

    override func install() -> Token? {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ptr in
            guard let ptr = ptr else { return }
            let me = Unmanaged<BatteryObserver>.fromOpaque(ptr).takeUnretainedValue()
            me.fire()
        }
        guard let src = IOPSNotificationCreateRunLoopSource(callback, ctx)?.takeRetainedValue() else {
            // IOKit power services unavailable / denied. Return nil so the
            // base class retries on the next subscribe — pull-based readers
            // (Battery.percent) still work in the meantime.
            FileHandle.standardError.write(Data("stackd: BatteryObserver — IOPS source creation failed\n".utf8))
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        return Token {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
    }
}

enum Battery {
    private static func sources() -> (snapshot: CFTypeRef, list: [CFTypeRef])? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        return (snap, list)
    }

    static func percent() -> Int {
        guard let s = sources() else { return -1 }
        for ps in s.list {
            if let desc = IOPSGetPowerSourceDescription(s.snapshot, ps)?.takeUnretainedValue() as? [String: Any],
               let cap = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return Int((Double(cap) * 100.0 / Double(max)).rounded())
            }
        }
        return -1
    }

    static func isCharging() -> Bool {
        guard let s = sources() else { return false }
        for ps in s.list {
            if let desc = IOPSGetPowerSourceDescription(s.snapshot, ps)?.takeUnretainedValue() as? [String: Any],
               let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
        }
        return false
    }

    // Pulls the first power-source description dict — same path as percent() /
    // isCharging(). All IOPS-sourced fields below share this lookup so a
    // single snapshot read covers the whole batch from the consumer's POV
    // (caller still re-enters per field, but each call is cheap).
    private static func firstDesc() -> [String: Any]? {
        guard let s = sources() else { return nil }
        for ps in s.list {
            if let desc = IOPSGetPowerSourceDescription(s.snapshot, ps)?.takeUnretainedValue() as? [String: Any] {
                return desc
            }
        }
        return nil
    }

    // --- IOPS power-source description fields ---

    /// Remaining minutes on battery. nil on AC / desktops / while estimating
    /// (the IOPS dict returns `kIOPSTimeRemainingUnknown` (-1) in that case —
    /// surface that as nil for stack authors instead of leaking the sentinel).
    static func timeRemaining() -> Int? {
        guard let v = firstDesc()?[kIOPSTimeToEmptyKey] as? Int, v >= 0 else { return nil }
        return v
    }

    /// "Is Finishing Charge" — trickle-charging the final few percent.
    static func isFinishingCharge() -> Bool? {
        (firstDesc()?[kIOPSIsFinishingChargeKey] as? NSNumber)?.boolValue
    }

    /// Raw IOPS current capacity (mAh on Apple Silicon when AppleSmartBattery
    /// exposes it; on some power sources this is a 0–100 percentage instead —
    /// surface as-is, matches `hs.battery.capacity()` shape).
    static func currentCapacity() -> Int? {
        firstDesc()?[kIOPSCurrentCapacityKey] as? Int
    }

    /// IOPS max capacity. Often 100 (percentage) at the IOPS layer; the true
    /// mAh max is on AppleSmartBattery — see `appleSmartMaxCapacity()` if you
    /// need that. Kept for parity with `hs.battery.maxCapacity`'s primary path.
    static func maxCapacity() -> Int? {
        firstDesc()?[kIOPSMaxCapacityKey] as? Int
    }

    /// Design capacity in mAh. Apple Silicon exposes this on the IOPS dict.
    static func designCapacity() -> Int? {
        firstDesc()?[kIOPSDesignCapacityKey] as? Int
    }

    /// "Good" | "Fair" | "Poor" per IOPSKeys.h. Apple does NOT document a
    /// "Service" enum value on `kIOPSBatteryHealthKey` — that string comes
    /// from the separate `kIOPSBatteryHealthConditionKey` ("Check Battery" /
    /// "Permanent Battery Failure"), which is a sibling diagnostic. We surface
    /// only the three documented health values; condition can be added as a
    /// separate field if a stack asks for it.
    static func health() -> String? {
        firstDesc()?[kIOPSBatteryHealthKey] as? String
    }

    // --- AppleSmartBattery IORegistry fields ---

    /// Reads a numeric property off the AppleSmartBattery IORegistry entry.
    /// Returns nil on desktops / when the service isn't matched.
    private static func smartInt(_ key: String) -> Int? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        let cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)
        return cf?.takeRetainedValue() as? Int
    }

    /// Discharge cycle count from AppleSmartBattery.
    static func cycles() -> Int? { smartInt("CycleCount") }

    /// Instantaneous current flow in mA. Negative = discharging, positive =
    /// charging, ~0 = idle. Matches `hs.battery.amperage`.
    static func amperage() -> Int? { smartInt("Amperage") }

    /// Battery voltage in mV.
    static func voltage() -> Int? { smartInt("Voltage") }
}
