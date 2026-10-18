import Foundation

// SensorReader sits between the HID sensor SPI and the sensors snapshot. The
// SPI itself is replaced by a fake that counts how often it is asked for a
// client, the matching services and their names.

private final class FakeService: NSObject {
    let name: String
    var value: Double?
    init(_ name: String, _ value: Double?) {
        self.name = name
        self.value = value
    }
}

private final class FakeSensorBackend: SensorBackend {
    var servicesByUsage: [Int: [FakeService]] = [:]
    var failClientCreation = 0
    private(set) var clientsMade = 0
    private(set) var serviceQueries = 0
    private(set) var nameReads = 0
    private(set) var valueReads = 0

    func makeClient() -> AnyObject? {
        if failClientCreation > 0 {
            failClientCreation -= 1
            return nil
        }
        clientsMade += 1
        return NSObject()
    }

    func services(client: AnyObject, usage: Int) -> CFArray? {
        serviceQueries += 1
        guard let list = servicesByUsage[usage] else { return nil }
        return list as NSArray as CFArray
    }

    func productName(service: AnyObject) -> String {
        nameReads += 1
        return (service as? FakeService)?.name ?? "Unknown"
    }

    func value(service: AnyObject, eventType: Int64, field: Int32) -> Double? {
        valueReads += 1
        return (service as? FakeService)?.value
    }
}

func registerSensorReaderTests() {
    // HID usages on the Apple vendor page.
    let temperature = 0x0005, voltage = 0x0002, current = 0x0003, fan = 0x000b

    func rows(_ snapshot: [String: Any], _ key: String) -> [[String: Any]] {
        (snapshot[key] as? [[String: Any]]) ?? []
    }

    test("SensorReader: reports temperatures, voltages, currents and fans with units and rounding") {
        let backend = FakeSensorBackend()
        backend.servicesByUsage[temperature] = [FakeService("PMU tdie1", 41.2345)]
        backend.servicesByUsage[voltage] = [FakeService("VBAT", 12.5)]
        backend.servicesByUsage[current] = [FakeService("IBAT", 0.256)]
        backend.servicesByUsage[fan] = [FakeService("Fan 0", 1234.6)]
        let snap = SensorReader(backend: backend).snapshot()

        let temps = rows(snap, "temperatures")
        try expectEqual(temps.count, 1)
        try expectEqual(temps.first?["name"] as? String, "PMU tdie1")
        try expectEqual(temps.first?["value"] as? Double, 41.23)
        try expectEqual(temps.first?["unit"] as? String, "°C")
        try expectEqual(rows(snap, "voltages").first?["unit"] as? String, "V")
        try expectEqual(rows(snap, "currents").first?["value"] as? Double, 0.26)
        try expectEqual(rows(snap, "currents").first?["unit"] as? String, "A")
        try expectEqual(rows(snap, "fans").first?["rpm"] as? Int, 1235)
    }

    test("SensorReader: drops non-finite readings, missing events and stopped fans") {
        let backend = FakeSensorBackend()
        backend.servicesByUsage[temperature] = [
            FakeService("nan", .nan), FakeService("none", nil), FakeService("ok", 30)]
        backend.servicesByUsage[fan] = [FakeService("stopped", 0), FakeService("negative", -5), FakeService("ok", 900)]
        let snap = SensorReader(backend: backend).snapshot()
        try expectEqual(rows(snap, "temperatures").map { $0["name"] as? String ?? "" }, ["ok"])
        try expectEqual(rows(snap, "fans").map { $0["name"] as? String ?? "" }, ["ok"])
    }

    test("SensorReader: a usage with no services reports an empty array") {
        let snap = SensorReader(backend: FakeSensorBackend()).snapshot()
        for key in ["temperatures", "voltages", "currents", "fans"] {
            try expect(snap[key] is [[String: Any]], key)
            try expectEqual(rows(snap, key).count, 0, key)
        }
    }

    test("SensorReader: a second snapshot reuses the client, the services and the names") {
        let backend = FakeSensorBackend()
        backend.servicesByUsage[temperature] = [FakeService("a", 1), FakeService("b", 2)]
        backend.servicesByUsage[voltage] = [FakeService("v", 3)]
        let reader = SensorReader(backend: backend)

        _ = reader.snapshot()
        let clients = backend.clientsMade, queries = backend.serviceQueries, names = backend.nameReads
        try expectEqual(clients, 1)
        try expectEqual(queries, 4, "one service query per usage, empty ones included")

        let second = reader.snapshot()
        try expectEqual(backend.clientsMade, clients)
        try expectEqual(backend.serviceQueries, queries)
        try expectEqual(backend.nameReads, names)
        try expectEqual(rows(second, "temperatures").count, 2)
    }

    test("SensorReader: readings are taken fresh on every snapshot") {
        let backend = FakeSensorBackend()
        let probe = FakeService("a", 40)
        backend.servicesByUsage[temperature] = [probe]
        let reader = SensorReader(backend: backend)
        try expectEqual(rows(reader.snapshot(), "temperatures").first?["value"] as? Double, 40)
        probe.value = 55
        try expectEqual(rows(reader.snapshot(), "temperatures").first?["value"] as? Double, 55)
    }

    test("SensorReader: reset makes the next snapshot look the sensors up again") {
        let backend = FakeSensorBackend()
        backend.servicesByUsage[temperature] = [FakeService("a", 1)]
        let reader = SensorReader(backend: backend)
        _ = reader.snapshot()
        reader.reset()
        _ = reader.snapshot()
        try expectEqual(backend.clientsMade, 2)
        try expectEqual(backend.serviceQueries, 8)
    }

    test("SensorReader: a failed client creation is retried on the next snapshot") {
        let backend = FakeSensorBackend()
        backend.failClientCreation = 1
        backend.servicesByUsage[temperature] = [FakeService("a", 1)]
        let reader = SensorReader(backend: backend)
        try expectEqual(rows(reader.snapshot(), "temperatures").count, 0)
        try expectEqual(rows(reader.snapshot(), "temperatures").count, 1)
    }
}
