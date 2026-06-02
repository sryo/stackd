import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.hid
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - Sensors (HID thermal/voltage/current/fan)

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

/// 2s base poll. IOHIDEventSystem has no change-notification API for sensor
/// values, so we pull on a timer like Host does. Tuned to match the Host
/// channel — stacks that overlay CPU% on top of CPU temps get a consistent
/// cadence. Per-stack fanout can be slowed further via
/// `sd.sensors.subscribe(fn, { interval })`: the bridge gates the JSON +
/// evaluateJavaScript hop per stack (see Bridge.channelIntervals); the
/// native poll itself stays at 2s because other subscribers may want it.
final class SensorsObserver: RefCountedObserver {
    static let shared = SensorsObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Lazy fire: temps/fans are rounded to 2 decimals at query time
            // (Sensors.swift:98), so a system that's sitting idle hashes the
            // same every tick — the per-stack push gets skipped. Active
            // workloads will see the hash change every tick, identical to
            // the previous always-fire behavior.
            let snap = Sensors.snapshot()
            if let data = try? JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys]) {
                self.fireIfChanged("sensors", hash: data.hashValue)
            } else {
                self.fire()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        return Token { t.invalidate() }
    }
}

// MARK: - Battery (IOPS + AppleSmartBattery)

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

// MARK: - Host (CPU/memory/GPU/system info)

enum Host {
    /// One-shot system info: hostname, OS, locale, arch, cpu count, RAM.
    /// Cheap to call — every field reads from APIs that are effectively
    /// constant for the life of the process, so no caching needed.
    static func info() -> [String: Any] {
        let pinfo = ProcessInfo.processInfo
        let v = pinfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"

        // preferredLanguages reflects the user's chosen UI language (e.g. "en-US",
        // "es-419"), which is what stacks want for region-aware copy. Locale.current
        // is the formatting locale — close, but not always what's shown in the
        // language pref pane. Fall back to identifier if the list is empty.
        let locale = pinfo.environment["LANG"].flatMap { String($0.split(separator: ".").first ?? "") }.flatMap { $0.isEmpty ? nil : $0 }
            ?? Locale.preferredLanguages.first?.replacingOccurrences(of: "-", with: "_")
            ?? Locale.current.identifier

        return [
            "hostname": pinfo.hostName,
            "os": [
                "name":    "macOS",
                "version": version,
                "build":   osBuild()
            ],
            "locale":   locale,
            "arch":     sysctlString("hw.machine") ?? "unknown",
            "cpuCount": sysctlInt("hw.physicalcpu") ?? Int(pinfo.processorCount),
            "ramMB":    Int(pinfo.physicalMemory / 1_048_576)
        ]
    }

    /// Polled snapshot used by Bridge.startHost to push the channel every 2s.
    /// Returns nil on the very first call (CPU fractions need a prior tick to
    /// diff against) and on rare sysctl/mach failures. Bridge skips nil pushes
    /// so the JS channel just sees the next valid tick.
    static func loadSnapshot() -> [String: Any]? {
        guard let cpu = cpuFractions() else { return nil }
        var out: [String: Any] = [
            "cpu":         cpu,
            "idleSeconds": idleSeconds()
        ]
        if let mem = memoryMB() { out["memoryMB"] = mem }
        if let pressure = memoryPressureLevel() { out["memoryPressure"] = pressure }
        if let swap = swapMB() { out["swap"] = swap }
        if let gpu = gpuUsage() { out["gpu"] = gpu }
        return out
    }

    // MARK: - CPU

    // Previous host_processor_info tick totals, kept across calls so each
    // poll computes deltas against the last one. nil means "no prior tick" —
    // loadSnapshot() returns nil and the observer fires once more 2s later.
    private static var lastCpuTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    private static func cpuFractions() -> [String: Double]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(),
                                     PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info = info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            user   += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            idle   += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            nice   += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }

        guard let prev = lastCpuTicks else {
            lastCpuTicks = (user, system, idle, nice)
            return nil
        }
        let dUser   = user   &- prev.user
        let dSystem = system &- prev.system
        let dIdle   = idle   &- prev.idle
        let dNice   = nice   &- prev.nice
        let dTotal  = dUser + dSystem + dIdle + dNice
        lastCpuTicks = (user, system, idle, nice)
        guard dTotal > 0 else { return nil }

        let total = Double(dTotal)
        let userF = Double(dUser + dNice) / total
        let sysF  = Double(dSystem) / total
        let idleF = Double(dIdle) / total
        return [
            "user":   round3(userF),
            "system": round3(sysF),
            "idle":   round3(idleF),
            "total":  round3(userF + sysF)
        ]
    }

    // MARK: - Idle time

    private static func idleSeconds() -> Double {
        // CGEventType(rawValue: ~0) is the documented "any event" sentinel.
        // CGEventSource.secondsSinceLastEventType counts time since the last
        // HID event of the requested type in the combined-session state —
        // exactly what every screensaver / autolock implementation reads.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        return (s * 10).rounded() / 10
    }

    // MARK: - Memory

    private static func memoryMB() -> [String: Int]? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let mb: (UInt64) -> Int = { Int(($0 * pageSize) / 1_048_576) }
        let free  = mb(UInt64(stats.free_count))
        let wired = mb(UInt64(stats.wire_count))
        let used  = mb(UInt64(stats.active_count) + UInt64(stats.inactive_count) + UInt64(stats.wire_count))
        return ["used": used, "free": free, "wired": wired]
    }

    // MARK: - Memory pressure / swap / GPU

    // kern.memorystatus_vm_pressure_level: 1=normal, 2=warning, 4=critical.
    // Same source NSProcessInfoMemoryPressureNotification uses, single sysctl
    // per tick instead of NotificationCenter wiring.
    private static func memoryPressureLevel() -> String? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        switch level {
        case 2: return "warning"
        case 4: return "critical"
        default: return "normal"
        }
    }

    private static func swapMB() -> [String: Int]? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return [
            "totalMB": Int(usage.xsu_total / 1_048_576),
            "usedMB":  Int(usage.xsu_used  / 1_048_576)
        ]
    }

    // MARK: - Per-disk I/O rates

    // Per-BSD-device cumulative byte counters from the previous diskIO()
    // call, plus the monotonic timestamp of that read. Diffing against the
    // next call gives bytes-per-second rates without needing a polling
    // observer — stacks just call diskIO() on whatever cadence they want
    // and the first call seeds the baseline. Protected by an NSLock because
    // diskIO() runs on the main thread from the Bridge sync handler today,
    // but callers may move to a background queue later.
    private struct DiskIOSample {
        let bytesRead:    UInt64
        let bytesWritten: UInt64
        let timestamp:    TimeInterval
    }
    private static var diskIOSamples: [String: DiskIOSample] = [:]
    private static let diskIOLock = NSLock()

    /// Pure rate-of-change helper. Bytes per second between two cumulative
    /// samples. Returns 0 for any degenerate input (no elapsed time, clock
    /// skew, counter reset on remount) so consumers always get a finite
    /// non-negative number — the next call will re-baseline naturally.
    /// Extracted as a static helper so HostDiskIOTests can hammer the math
    /// in isolation; the surrounding IOKit walk is impure and not tested.
    static func computeRate(before: UInt64, after: UInt64, elapsed: Double) -> Double {
        guard elapsed > 0, after >= before else { return 0 }
        let delta = after - before
        return Double(delta) / elapsed
    }

    /// One-shot per-disk I/O snapshot. Walks `IOBlockStorageDriver` matches
    /// in the IORegistry, reads each node's `Statistics` dict for cumulative
    /// byte / operation counts, and diffs against the previous diskIO() call
    /// to compute bytes-per-second rates. First call seeds the baseline —
    /// rates appear from the second call onward. Stats.app uses this exact
    /// walk; reference implementation lives in their `IOService` extension.
    ///
    /// Returns one entry per block device:
    ///   { name, bytesRead, bytesWritten,
    ///     readsPerSecond?, writesPerSecond? }
    /// `name` is the BSD identifier (e.g. "disk0", "disk1s2") from the
    /// `BSD Name` property — the same string users see in `diskutil list`.
    /// Cumulative byte counts are always present; the per-second rates are
    /// only emitted once a prior sample exists to diff against.
    static func diskIO() -> [[String: Any]] {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return [] }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        let now = ProcessInfo.processInfo.systemUptime
        var out: [[String: Any]] = []
        var nextSamples: [String: DiskIOSample] = [:]

        diskIOLock.lock()
        defer { diskIOLock.unlock() }

        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }

            // `BSD Name` lives on the IOMedia child, not the IOBlockStorageDriver
            // node itself. IORegistryEntrySearchCFProperty with kIORegistryIterateRecursively
            // walks into children to find it — same trick Stats.app uses.
            // (Auto-bridged return value: already retained per the +1 rule, no
            // Unmanaged hop required by the Swift import.)
            let bsdName: String = {
                guard let cf = IORegistryEntrySearchCFProperty(
                    service,
                    kIOServicePlane,
                    "BSD Name" as CFString,
                    kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively)
                ) else { return "unknown" }
                return (cf as? String) ?? "unknown"
            }()

            // Statistics dict is on the IOBlockStorageDriver node directly.
            // Keys have literal spaces + parens: "Bytes (Read)", "Bytes (Write)",
            // "Operations (Read)", "Operations (Write)". CFNumber values are
            // UInt64 cumulative counters that monotonically increase until the
            // device disappears.
            guard let statsRef = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            let bytesRead    = (statsRef["Bytes (Read)"]       as? UInt64) ?? 0
            let bytesWritten = (statsRef["Bytes (Write)"]      as? UInt64) ?? 0
            let opsRead      = (statsRef["Operations (Read)"]  as? UInt64) ?? 0
            let opsWritten   = (statsRef["Operations (Write)"] as? UInt64) ?? 0

            var entry: [String: Any] = [
                "name":         bsdName,
                "bytesRead":    bytesRead,
                "bytesWritten": bytesWritten,
                "opsRead":      opsRead,
                "opsWritten":   opsWritten
            ]

            if let prev = diskIOSamples[bsdName] {
                let elapsed = now - prev.timestamp
                entry["bytesReadPerSecond"]    = computeRate(before: prev.bytesRead,    after: bytesRead,    elapsed: elapsed)
                entry["bytesWrittenPerSecond"] = computeRate(before: prev.bytesWritten, after: bytesWritten, elapsed: elapsed)
            }

            nextSamples[bsdName] = DiskIOSample(
                bytesRead:    bytesRead,
                bytesWritten: bytesWritten,
                timestamp:    now
            )
            out.append(entry)
        }

        diskIOSamples = nextSamples
        return out
    }

    // Matching the "IOAccelerator" class catches both Apple Silicon's AGX and
    // older Intel iGPU + discrete cards via the IOKit class hierarchy. Max
    // across services so an idle iGPU doesn't shadow a busy dGPU.
    private static func gpuUsage() -> [String: Any]? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        var best = -1
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            guard let prop = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            if let util = prop["Device Utilization %"] as? Int, util > best { best = util }
        }
        guard best >= 0 else { return nil }
        return ["usagePercent": best]
    }

    // MARK: - Helpers

    private static func round3(_ d: Double) -> Double {
        (d * 1000).rounded() / 1000
    }

    private static func osBuild() -> String {
        // sysctl kern.osversion is the "24C101"-style build string Apple ships;
        // ProcessInfo doesn't expose it directly.
        sysctlString("kern.osversion") ?? ""
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

/// 2s base poll for CPU + idle + memory. The CPU fractions are computed by
/// diffing the previous tick, so the first fire returns nil (Bridge skips the
/// push) and the second fire — 2s later — pushes the first real value.
/// Per-stack fanout can be slowed further via
/// `sd.host.load.subscribe(fn, { interval })`: the bridge gates the JSON +
/// evaluateJavaScript hop per stack (see Bridge.channelIntervals); the
/// native poll itself stays at 2s because the CPU diff depends on a steady
/// sampling baseline regardless of how often any one stack listens.
final class HostObserver: RefCountedObserver {
    static let shared = HostObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(t, forMode: .common)
        return Token { t.invalidate() }
    }
}

// MARK: - Caffeinate (sleep + screen-lock state)

// System sleep + screen-lock state. Pure observer — no assertion API yet
// (IOPMAssertionCreateWithName would be the v2 addition for "prevent sleep
// while my recording stack is open" use cases).
//
// Three consumers from the audit:
//  - apptimeout: don't accumulate windowless time while the screen is locked
//  - timetrail: stop drawing while screen is off
//  - undoclose: ignore destroyed bangs during logout / screen-lock burst
enum Caffeinate {
    /// Snapshot used by Bridge to push the initial signal value.
    /// `sleeping` flips true between willSleep and didWake. `locked` flips
    /// true between screenIsLocked and screenIsUnlocked. CGSSession lets us
    /// resolve `locked` at startup so a stack that loads while the screen is
    /// already locked sees the correct initial state.
    static func snapshot() -> [String: Any] {
        return [
            "sleeping": CaffeinateObserver.shared.sleepingFlag,
            "locked":   CaffeinateObserver.shared.lockedFlag
        ]
    }

    /// Reads the current CGSession lock state (true if screen is locked).
    /// Used once at observer install to seed `lockedFlag`.
    fileprivate static func currentlyLocked() -> Bool {
        // Auto-bridges to CFDictionary on modern Swift; no Unmanaged hop.
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = dict["CGSSessionScreenIsLocked"] as? Bool
        else { return false }
        return locked
    }

    // MARK: - Assertions (setter side of caffeinate)

    /// Holds a power-management assertion until release() is called. Three JS
    /// types map to three IOPM assertion strings:
    ///   - "display"      → kIOPMAssertionTypeNoDisplaySleep
    ///       (keeps the display awake while the assertion is held; user idle
    ///        timer doesn't dim or sleep the screen)
    ///   - "system"       → kIOPMAssertionTypeNoIdleSleep
    ///       (system stays awake even when user is idle; display may still
    ///        sleep on its own timer)
    ///   - "userActivity" → kIOPMAssertionTypePreventUserIdleSystemSleep
    ///       (advisory equivalent — same intent as "system" but bound to the
    ///        user-idle path; respects external power policy)
    /// Returns the raw IOPMAssertionID on success, nil on failure. Bridge
    /// owns the lifetime — assertions are released at stack unload via the
    /// scope drain, or explicitly via Caffeinate.release(id:).
    static func assert(type: String, reason: String) -> IOPMAssertionID? {
        let assertionType: CFString
        switch type {
        case "display":      assertionType = kIOPMAssertionTypeNoDisplaySleep as CFString
        case "system":       assertionType = kIOPMAssertionTypeNoIdleSleep as CFString
        case "userActivity": assertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        default:
            FileHandle.standardError.write(Data("stackd: caffeinate.assert — unknown type \(type)\n".utf8))
            return nil
        }
        // Reason string is surfaced in `pmset -g assertions` / Activity Monitor,
        // so stacks should pass something descriptive. Empty falls back to a
        // generic label so the entry isn't anonymous.
        let label = reason.isEmpty ? "stackd assertion" : reason
        var assertionId: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            label as CFString,
            &assertionId
        )
        guard result == kIOReturnSuccess else {
            FileHandle.standardError.write(Data("stackd: caffeinate.assert — IOPMAssertionCreateWithName failed (\(result))\n".utf8))
            return nil
        }
        return assertionId
    }

    /// Releases an assertion minted by `assert(type:reason:)`. Safe to call
    /// with a stale id — IOPMAssertionRelease returns an error code which we
    /// swallow (the alternative is leaking the slot, since callers have no
    /// useful recovery). No-op on kIOPMNullAssertionID.
    @discardableResult
    static func release(id: IOPMAssertionID) -> Bool {
        guard id != IOPMAssertionID(kIOPMNullAssertionID) else { return false }
        return IOPMAssertionRelease(id) == kIOReturnSuccess
    }
}

final class CaffeinateObserver: RefCountedObserver {
    static let shared = CaffeinateObserver()
    private override init() { super.init() }

    // State the observer maintains across notifications. Read by Caffeinate.snapshot()
    // when Bridge needs to push the channel.
    fileprivate var sleepingFlag: Bool = false
    fileprivate var lockedFlag: Bool = false

    override func install() -> Token {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()

        // Seed lock state once; sleep starts false (we only observe transitions).
        lockedFlag = Caffeinate.currentlyLocked()
        sleepingFlag = false

        // The screensaver and lock-screen notifications come from
        // DistributedNotificationCenter, not the workspace center — they're
        // posted by loginwindow, not NSWorkspace. Same shape Hammerspoon uses
        // for hs.caffeinate.watcher's lockScreen / unlockScreen events.
        return installNotifications([
            (ws, NSWorkspace.willSleepNotification, { [weak self] _ in
                self?.sleepingFlag = true
                self?.fire()
            }),
            (ws, NSWorkspace.didWakeNotification, { [weak self] _ in
                self?.sleepingFlag = false
                self?.fire()
            }),
            (dn, Notification.Name("com.apple.screenIsLocked"), { [weak self] _ in
                self?.lockedFlag = true
                self?.fire()
            }),
            (dn, Notification.Name("com.apple.screenIsUnlocked"), { [weak self] _ in
                self?.lockedFlag = false
                self?.fire()
            })
        ])
    }
}
