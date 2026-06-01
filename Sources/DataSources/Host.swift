import AppKit
import Darwin
import Foundation

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
