import Foundation
import IOKit.ps

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
}
