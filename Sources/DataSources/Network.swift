import Foundation
import SystemConfiguration
import CoreWLAN
import Network
import Darwin

enum NetLAN {
    static func current() -> [String: Any] {
        return [
            "ipv4":     primaryIPv4()        as Any? ?? NSNull(),
            "hostname": Foundation.Host.current().localizedName ?? ""
        ]
    }

    private static func primaryIPv4() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "stackd.netlan" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryService"] as? String,
              let svc = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(primary)/IPv4" as CFString) as? [String: Any],
              let addrs = svc["Addresses"] as? [String]
        else { return nil }
        return addrs.first
    }
}

enum NetWiFi {
    static func current() -> [String: Any] {
        guard let iface = CWWiFiClient.shared().interface() else {
            return ["ssid": NSNull(), "signal": NSNull()]
        }
        // macOS 14.4+: ssid() returns nil unless Location TCC is granted.
        // We surface nil rather than asking — themes can render a "?" state.
        return [
            "ssid":   iface.ssid()  as Any? ?? NSNull(),
            "signal": iface.rssiValue()
        ]
    }
}

/// One shared NWPathMonitor that fires both LAN and WiFi subscribers.
/// Polled callback (not raw NWPath) because most state we care about
/// (SSID, IP address) needs a separate read, not the path object itself.
/// `latestPath` is cached for sd.net.path consumers that DO want the raw
/// flags — same fanout, no parallel monitor. Main-queue access only.
final class NetworkObserver: RefCountedObserver {
    static let shared = NetworkObserver()
    private override init() { super.init() }

    private(set) var latestPath: NWPath?

    override func install() -> Token {
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.latestPath = path
                self?.fire()
            }
        }
        mon.start(queue: DispatchQueue.global(qos: .utility))
        return Token { [weak self] in
            mon.cancel()
            self?.latestPath = nil
        }
    }
}

/// Summarize an NWPath into the dict shape sd.net.path subscribers receive.
enum NetPath {
    private static let statusNames: [NWPath.Status: String] = [
        .satisfied:          "satisfied",
        .unsatisfied:        "unsatisfied",
        .requiresConnection: "requiresConnection"
    ]
    private static let interfaceNames: [NWInterface.InterfaceType: String] = [
        .wifi:          "wifi",
        .wiredEthernet: "wired",
        .cellular:      "cellular",
        .loopback:      "loopback",
        .other:         "other"
    ]

    static func snapshot(from path: NWPath) -> [String: Any] {
        // availableInterfaces is ordered by preference (primary first) —
        // preserve that order so consumers can read index 0 as the active route.
        let interfaces = path.availableInterfaces.map { interfaceNames[$0.type] ?? "other" }
        return [
            "status":         statusNames[path.status] ?? "unsatisfied",
            "interfaces":     interfaces,
            "isConstrained":  path.isConstrained,
            "isExpensive":    path.isExpensive
        ]
    }
}

// MARK: - sd.net.throughput

/// Pure interface-byte sum + rate math. Split from the observer so the diff
/// logic is unit-testable without a Timer or AF_LINK getifaddrs walk.
enum NetThroughput {
    /// Walks getifaddrs() once, sums `if_data.ifi_ibytes` / `ifi_obytes`
    /// across every non-loopback link-level (AF_LINK) entry. Loopback is
    /// skipped to match the netstat-ib parser that the bar/items/throughput
    /// stack previously implemented in JS — without that skip, a single
    /// localhost-heavy app (Docker, dev proxy) would dominate the rate.
    static func interfaceTotals() -> (rx: UInt64, tx: UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let entry = p.pointee
            if let sa = entry.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: entry.ifa_name)
                if !name.hasPrefix("lo"),
                   let dataPtr = entry.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    rx &+= UInt64(dataPtr.pointee.ifi_ibytes)
                    tx &+= UInt64(dataPtr.pointee.ifi_obytes)
                }
            }
            ptr = entry.ifa_next
        }
        return (rx, tx)
    }

    /// Diff math. Returns nil when there's no prior sample (first tick) or
    /// time hasn't advanced. Clamps negative deltas to 0 so a counter wrap
    /// or interface tear-down doesn't surface a negative rate to JS.
    static func computeRates(
        prevRx: UInt64, prevTx: UInt64, prevTs: TimeInterval,
        curRx:  UInt64, curTx:  UInt64, curTs:  TimeInterval
    ) -> (rxBps: Double, txBps: Double)? {
        guard prevTs > 0, curTs > prevTs else { return nil }
        let dt = curTs - prevTs
        let dRx = curRx > prevRx ? Double(curRx - prevRx) : 0
        let dTx = curTx > prevTx ? Double(curTx - prevTx) : 0
        return (dRx / dt, dTx / dt)
    }
}

/// 1s polling observer for aggregate network throughput. Like
/// SensorsObserver / HostObserver, kicks a Timer on install and tears it
/// down when the last subscriber leaves. Cached `current` so multiple
/// bridges fanning out on the same tick read the same diff (calling
/// snapshot twice on a static-state struct would zero the second read).
final class NetworkThroughputObserver: RefCountedObserver {
    static let shared = NetworkThroughputObserver()
    private override init() { super.init() }

    /// Latest snapshot, refreshed on each tick. nil until the first diff
    /// is available — matches startChannel's "no data yet → skip push"
    /// contract.
    private(set) var current: [String: Any]?
    private var prevRx: UInt64 = 0
    private var prevTx: UInt64 = 0
    private var prevTs: TimeInterval = 0

    override func install() -> Token {
        prevRx = 0; prevTx = 0; prevTs = 0; current = nil
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        return Token { [weak self] in
            t.invalidate()
            self?.current = nil
            self?.prevRx = 0; self?.prevTx = 0; self?.prevTs = 0
        }
    }

    private func tick() {
        let (rx, tx) = NetThroughput.interfaceTotals()
        let now = Date().timeIntervalSince1970
        if let rates = NetThroughput.computeRates(
            prevRx: prevRx, prevTx: prevTx, prevTs: prevTs,
            curRx:  rx,     curTx:  tx,     curTs:  now
        ) {
            current = [
                "rxBps":   rates.rxBps,
                "txBps":   rates.txBps,
                "rxBytes": rx,
                "txBytes": tx
            ]
        }
        prevRx = rx; prevTx = tx; prevTs = now
        fire()
    }
}
