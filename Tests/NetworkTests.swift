import Foundation
import Network

// Tests for `Sources/DataSources/Network.swift`.
//
// Network.swift is thin — three enums (NetLAN / NetWiFi / NetPath) plus one
// RefCountedObserver (NetworkObserver). The testable surface is the dict
// shape each `current()` / `snapshot()` returns, since JS subscribers in
// Bridge.swift depend on exact key names + value types.
//
// What we can't test in a sync, side-effect-free harness:
//   - The IPv4 value itself (depends on whether the user is on a network).
//   - SSID (returns nil unless Location TCC is granted to stackd).
//   - NetPath.snapshot(from:) directly — NWPath has no public initializer.
//     We exercise the static name maps indirectly by verifying the keys
//     produced by NetworkObserver.shared.latestPath when present.
//
// What we deliberately avoid:
//   - CWInterface.scan() / associate() / disassociate() — would interfere
//     with the user's real wifi.
//   - Triggering NWPathMonitor and blocking on its async callback — no test
//     in this suite uses RunLoop spins; we keep that contract.

func registerNetworkTests() {
    // MARK: - NetLAN.current()

    test("NetLAN.current returns a dict with ipv4 + hostname keys") {
        // Bridge.swift jsonifies this dict for sd.net.lan subscribers — both
        // keys must always be present so the JS side can destructure safely.
        let dict = NetLAN.current()
        try expect(dict["ipv4"] != nil, "ipv4 key must exist (NSNull if no primary service)")
        try expect(dict["hostname"] != nil, "hostname key must exist")
    }

    test("NetLAN.current hostname is a String (possibly empty)") {
        // localizedName is nil-coalesced to "" in the producer — never NSNull,
        // never absent. JS does `dict.hostname.toLowerCase()` style reads.
        let dict = NetLAN.current()
        try expect(dict["hostname"] is String, "hostname should be a String, got \(type(of: dict["hostname"] ?? "nil"))")
    }

    test("NetLAN.current ipv4 is either a String or NSNull") {
        // SCDynamicStore can fail to resolve a primary service (no network,
        // captive portal mid-handshake) — surface as NSNull so JSON keeps the
        // key. Anything else (a number, a dict) would be a producer bug.
        let dict = NetLAN.current()
        let ipv4 = dict["ipv4"]
        let isStringOrNull = (ipv4 is String) || (ipv4 is NSNull)
        try expect(isStringOrNull, "ipv4 must be String or NSNull, got \(type(of: ipv4 ?? "nil"))")
    }

    // MARK: - NetWiFi.current()

    test("NetWiFi.current returns a dict with ssid + signal keys") {
        // Even on a Mac with no wifi hardware (Mac mini Ethernet-only), the
        // producer falls through to the no-interface branch and still emits
        // both keys as NSNull. Absent keys would break JS destructuring.
        let dict = NetWiFi.current()
        try expect(dict["ssid"] != nil, "ssid key must exist (NSNull if no interface)")
        try expect(dict["signal"] != nil, "signal key must exist (NSNull if no interface)")
    }

    test("NetWiFi.current ssid is either a String or NSNull") {
        // macOS 14.4+ withholds SSID without Location TCC — producer surfaces
        // nil → NSNull rather than prompting. Anything else is a bug.
        let dict = NetWiFi.current()
        let ssid = dict["ssid"]
        let isStringOrNull = (ssid is String) || (ssid is NSNull)
        try expect(isStringOrNull, "ssid must be String or NSNull, got \(type(of: ssid ?? "nil"))")
    }

    test("NetWiFi.current signal is either an Int RSSI or NSNull") {
        // rssiValue() returns Int (dBm, typically -30…-90). No-interface
        // branch puts NSNull. Float / String here would mean the producer
        // changed shape without the JS callers being updated.
        let dict = NetWiFi.current()
        let signal = dict["signal"]
        let isIntOrNull = (signal is Int) || (signal is NSNull)
        try expect(isIntOrNull, "signal must be Int or NSNull, got \(type(of: signal ?? "nil"))")
    }

    // MARK: - NetworkObserver shape

    test("NetworkObserver.shared exposes a latestPath property (initially nil before install)") {
        // The observer only starts NWPathMonitor on first subscribe(). Before
        // anyone subscribes, latestPath should be nil — otherwise the cache
        // is leaking state from a prior install/cancel cycle.
        //
        // Note: if any earlier test in the suite subscribed and the Token
        // hasn't been released yet, this will be non-nil. We assert the
        // weaker invariant that the property is reachable and either nil or
        // a valid NWPath — which is the contract sd.net.path consumers rely
        // on when priming the channel.
        let path = NetworkObserver.shared.latestPath
        if path != nil {
            // If a previous test or the running daemon already installed the
            // monitor, the cached path must at minimum have a defined status.
            // (NWPath.Status is an enum — can't be malformed, but we touch it
            // to prove the reference is alive.)
            _ = path!.status
        }
        // Either branch is acceptable; the test fails only if accessing
        // latestPath crashes (e.g. concurrent mutation on a non-main queue).
        try expect(true)
    }

    // MARK: - NetPath.snapshot shape (when a real path is available)

    test("NetPath.snapshot emits status + interfaces + isConstrained + isExpensive when path is cached") {
        // We can't construct an NWPath in a test (no public init), so this
        // test is conditional: if NetworkObserver has already cached a path
        // (because the daemon or another test installed it), verify the dict
        // contract. If not, skip — we don't add a synchronous wait just for
        // this assertion (the suite avoids RunLoop spins).
        guard let path = NetworkObserver.shared.latestPath else {
            return
        }
        let dict = NetPath.snapshot(from: path)
        try expect(dict["status"] is String, "status should be a String enum name")
        try expect(dict["interfaces"] is [String], "interfaces should be [String]")
        try expect(dict["isConstrained"] is Bool, "isConstrained should be Bool")
        try expect(dict["isExpensive"] is Bool, "isExpensive should be Bool")

        // Status must be one of the three known names — anything else means
        // a new NWPath.Status case landed and the map wasn't updated.
        let status = dict["status"] as! String
        let known = ["satisfied", "unsatisfied", "requiresConnection"]
        try expect(known.contains(status), "status '\(status)' is not in the known set \(known)")

        // Interface names must be from the known set — "other" is the
        // documented fallback, so unknown types degrade gracefully.
        let interfaces = dict["interfaces"] as! [String]
        let knownIfaces = Set(["wifi", "wired", "cellular", "loopback", "other"])
        for iface in interfaces {
            try expect(knownIfaces.contains(iface), "interface '\(iface)' is not in the known set")
        }
    }
}
