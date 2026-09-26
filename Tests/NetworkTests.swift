import Foundation
import Network

// Tests for `Sources/DataSources/Network.swift`.
//
// The testable surface is the dict shape each `current()` / `snapshot()`
// returns (JS subscribers destructure these keys) plus the pure throughput
// rate math.
//
// Not covered:
//   - The IPv4 / SSID values themselves (depend on the host's network and on
//     Location TCC for SSID).
//   - NetPath.snapshot(from:) — NWPath has no public initializer, and getting
//     a real one means installing NetworkObserver's NWPathMonitor.
//   - CWInterface.scan() / associate() — would interfere with the user's wifi.

func registerNetworkTests() {
    // MARK: - NetLAN.current()

    test("NetLAN.current always carries ipv4 (String or NSNull) and hostname (String)") {
        // ipv4 is NSNull when SCDynamicStore has no primary service (offline,
        // captive portal mid-handshake); the key stays so JSON keeps it.
        let dict = NetLAN.current()
        let ipv4 = dict["ipv4"]
        try expect((ipv4 is String) || (ipv4 is NSNull),
                   "ipv4 must be String or NSNull, got \(type(of: ipv4 ?? "nil"))")
        try expect(dict["hostname"] is String,
                   "hostname should be a String, got \(type(of: dict["hostname"] ?? "nil"))")
    }

    // MARK: - NetWiFi.current()

    test("NetWiFi.current always carries ssid (String or NSNull) and signal (Int or NSNull)") {
        // Ethernet-only Macs take the no-interface branch (both NSNull);
        // macOS 14.4+ withholds SSID without Location TCC (NSNull, no prompt).
        let dict = NetWiFi.current()
        let ssid = dict["ssid"]
        let signal = dict["signal"]
        try expect((ssid is String) || (ssid is NSNull),
                   "ssid must be String or NSNull, got \(type(of: ssid ?? "nil"))")
        try expect((signal is Int) || (signal is NSNull),
                   "signal must be Int or NSNull, got \(type(of: signal ?? "nil"))")
    }

    // MARK: - NetThroughput.computeRates (pure diff math)

    test("NetThroughput.computeRates returns nil on first sample (prevTs == 0)") {
        // First tick has no prior sample — must skip rather than emit a
        // garbage rate computed against epoch 0.
        let rates = NetThroughput.computeRates(
            prevRx: 0, prevTx: 0, prevTs: 0,
            curRx:  1000, curTx: 2000, curTs: 1000.0
        )
        try expect(rates == nil, "first-tick rate should be nil, got \(String(describing: rates))")
    }

    test("NetThroughput.computeRates returns nil when time hasn't advanced") {
        let rates = NetThroughput.computeRates(
            prevRx: 100, prevTx: 100, prevTs: 1000.0,
            curRx:  200, curTx:  200, curTs:  1000.0
        )
        try expect(rates == nil, "zero-dt rate should be nil")
    }

    test("NetThroughput.computeRates divides byte delta by time delta") {
        // 1000 bytes rx in 2 seconds → 500 B/s.
        let rates = NetThroughput.computeRates(
            prevRx: 0,    prevTx: 0,    prevTs: 1000.0,
            curRx:  1000, curTx:  4000, curTs:  1002.0
        )
        try expect(rates != nil, "rates should be non-nil for a normal diff")
        try expectEqual(rates!.rxBps, 500.0)
        try expectEqual(rates!.txBps, 2000.0)
    }

    test("NetThroughput.computeRates clamps negative deltas to 0") {
        // Counter wrap or interface tear-down can produce curRx < prevRx.
        let rates = NetThroughput.computeRates(
            prevRx: 5000, prevTx: 5000, prevTs: 1000.0,
            curRx:  1000, curTx:  6000, curTs:  1001.0
        )
        try expect(rates != nil)
        try expectEqual(rates!.rxBps, 0.0)
        try expectEqual(rates!.txBps, 1000.0)
    }

    test("NetThroughput.interfaceTotals counters never go backwards between reads") {
        // The observer diffs successive reads; interface byte counters are
        // cumulative, so a second read taken right after the first must be
        // >= it (barring an interface disappearing mid-test).
        let first = NetThroughput.interfaceTotals()
        let second = NetThroughput.interfaceTotals()
        try expect(second.rx >= first.rx, "rx went backwards: \(first.rx) → \(second.rx)")
        try expect(second.tx >= first.tx, "tx went backwards: \(first.tx) → \(second.tx)")
    }
}
