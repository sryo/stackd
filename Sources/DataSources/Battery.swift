import Foundation
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
}
