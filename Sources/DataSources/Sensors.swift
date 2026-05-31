import Foundation
import IOKit
import IOKit.hid

// Per-die thermal + per-rail electrical + fan-RPM sensors via the private
// IOHIDEventSystemClient SPI. Same surface as asmagill's hs._asm.sensors —
// Apple silicon Macs expose 40+ thermal sensors and a handful of voltage /
// current / fan probes through HID services on the Apple vendor page (0xff00).
//
// Intel Macs use SMC keys for this data instead; not implemented here. On
// Intel the matching dictionary will simply enumerate zero services and the
// JS-side arrays come up empty.
//
// The IOHIDEventSystem entry points aren't in any public IOKit header but
// have been stable since 10.10 and ship in the IOKit dylib. We declare them
// via @_silgen_name so we don't have to vendor a private header.

// IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

// void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary)

// CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

// CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?

// IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, IOHIDEventType, IOHIDEventOptionBits, int64_t);
// asmagill calls with (type, 0, 0). The (Int64, Int32, Int64) calling convention
// matches the AArch64 ABI for the published prototype on macOS 13+.
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?

// IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef, IOHIDEventField);
// IOHIDFloat is a typedef of double; IOHIDEventField is an int32 = (type<<16)|offset.
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

private let kAppleVendorHIDPage: Int = 0xff00
private let kAppleVendorUsageTemperature: Int = 0x0005
private let kAppleVendorUsageVoltage: Int = 0x0002
private let kAppleVendorUsageCurrent: Int = 0x0003
private let kAppleVendorUsageFan: Int = 0x000b

private let kIOHIDEventTypeTemperatureValue: Int64 = 15
private let kIOHIDEventTypePowerValue: Int64 = 25

// IOHIDEventField is (type << 16) + offset. Temperature has one field (level).
// Power has three (measurement, type, subType); the measurement field is what
// holds the voltage / current value.
private let kIOHIDEventFieldTemperatureLevelValue: Int32 = Int32(15 << 16) + 0
private let kIOHIDEventFieldPowerMeasurementValue: Int32 = Int32(25 << 16) + 0

enum Sensors {
    /// Snapshot used by Bridge.startSensors to push the channel.
    /// Returns four parallel arrays. Empty arrays on Intel (different SMC
    /// surface entirely) or when the SPI returns no matches for a usage.
    static func snapshot() -> [String: Any] {
        return [
            "temperatures": query(usage: kAppleVendorUsageTemperature,
                                  eventType: kIOHIDEventTypeTemperatureValue,
                                  field: kIOHIDEventFieldTemperatureLevelValue,
                                  unit: "°C"),
            "voltages":     query(usage: kAppleVendorUsageVoltage,
                                  eventType: kIOHIDEventTypePowerValue,
                                  field: kIOHIDEventFieldPowerMeasurementValue,
                                  unit: "V"),
            "currents":     query(usage: kAppleVendorUsageCurrent,
                                  eventType: kIOHIDEventTypePowerValue,
                                  field: kIOHIDEventFieldPowerMeasurementValue,
                                  unit: "A"),
            "fans":         queryFans()
        ]
    }

    private static func query(usage: Int, eventType: Int64, field: Int32, unit: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        forEachService(usage: usage) { service in
            guard let event = IOHIDServiceClientCopyEvent(service, eventType, 0, 0)?.takeRetainedValue() else { return }
            let value = IOHIDEventGetFloatValue(event, field)
            // Filter NaN/Inf — the SPI returns garbage for sensors that
            // aren't currently powered (e.g. unused power rails).
            guard value.isFinite else { return }
            out.append([
                "name":  productName(of: service),
                "value": (value * 100).rounded() / 100,
                "unit":  unit
            ])
        }
        return out
    }

    private static func queryFans() -> [[String: Any]] {
        var out: [[String: Any]] = []
        forEachService(usage: kAppleVendorUsageFan) { service in
            // Fan probes on Apple silicon respond to temperature-shaped reads
            // (the SPI surfaces RPM as a "level" measurement on the same path).
            // Fanless Macs still expose unrelated HID services on usage 0xb
            // (e.g. internal keyboard / trackpad) — those return nil events
            // and naturally drop out here.
            guard let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperatureValue, 0, 0)?.takeRetainedValue() else { return }
            let rpm = IOHIDEventGetFloatValue(event, kIOHIDEventFieldTemperatureLevelValue)
            guard rpm.isFinite, rpm > 0 else { return }
            out.append([
                "name": productName(of: service),
                "rpm":  Int(rpm.rounded())
            ])
        }
        return out
    }

    // Iterate matched services without bridging through Swift's [AnyObject] —
    // IOHIDServiceClient handles are CF-only (no NSObject metadata) so a
    // Swift array cast triggers a SIGSEGV the moment ARC peeks at the slot.
    // CFArrayGetValueAtIndex + Unmanaged.fromOpaque is the safe path.
    private static func forEachService(usage: Int, _ body: (AnyObject) -> Void) {
        guard let clientRef = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        let client = clientRef.takeRetainedValue()
        let matching: [String: Any] = [
            "PrimaryUsagePage": kAppleVendorHIDPage,
            "PrimaryUsage":     usage
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        guard let arrayRef = IOHIDEventSystemClientCopyServices(client) else { return }
        let array = arrayRef.takeRetainedValue()
        let count = CFArrayGetCount(array)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let service = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            body(service)
        }
        _ = client  // keep client alive across the loop
    }

    private static func productName(of service: AnyObject) -> String {
        guard let prop = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() else {
            return "Unknown"
        }
        return (prop as? String) ?? "Unknown"
    }
}

/// 2s poll. IOHIDEventSystem has no change-notification API for sensor values,
/// so we pull on a timer like Host does. Tuned to match the Host channel —
/// stacks that overlay CPU% on top of CPU temps get a consistent cadence.
final class SensorsObserver: RefCountedObserver {
    static let shared = SensorsObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(t, forMode: .common)
        return Token { t.invalidate() }
    }
}
