import Foundation
import SystemConfiguration
import CoreWLAN
import Network

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
