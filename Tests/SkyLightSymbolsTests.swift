import Foundation

// Tests for `SkyLight.symbols` and the `stackd doctor` SPI check in
// Sources/Private/SkyLight.swift. dlsym misses degrade to nil by design, so a
// symbol an OS update removes turns its primitive into a silent no-op; the
// registry plus a live resolve test is what surfaces that.
func registerSkyLightSymbolsTests() {
    let sourcesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    func symLiteralsInSources() throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"SkyLight\.sym\("([A-Za-z0-9_]+)"\)"#)
        var names = Set<String>()
        let files = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let s = String(line)
                for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                    names.insert((s as NSString).substring(with: m.range(at: 1)))
                }
            }
        }
        return names
    }

    test("SkyLight: registry lists exactly the symbols Sources resolves") {
        let used = try symLiteralsInSources()
        try expect(!used.isEmpty, "scanner found no SkyLight.sym calls under \(sourcesDir.path)")
        let registered = Set(SkyLight.symbols)
        try expectEqual(used.subtracting(registered).sorted(), [], "resolved but not in SkyLight.symbols")
        try expectEqual(registered.subtracting(used).sorted(), [], "in SkyLight.symbols but never resolved")
        try expectEqual(SkyLight.symbols.count, registered.count, "duplicate entries in SkyLight.symbols")
    }

    test("SkyLight: missingSymbols reports only names the resolver rejects") {
        let missing = SkyLight.missingSymbols(resolve: { $0 != SkyLight.symbols[0] })
        try expectEqual(missing, [SkyLight.symbols[0]])
        try expectEqual(SkyLight.missingSymbols(resolve: { _ in true }), [])
    }

    test("SkyLight: doctor lines name each missing symbol, or confirm all resolve") {
        let bad = SkyLight.doctorLines(missing: ["SLSGone", "CGSAlsoGone"]).joined(separator: "\n")
        try expect(bad.contains("SLSGone") && bad.contains("CGSAlsoGone"), bad)
        try expect(bad.contains("❌"), bad)
        let ok = SkyLight.doctorLines(missing: []).joined(separator: "\n")
        try expect(ok.contains("\(SkyLight.symbols.count)"), ok)
        try expect(!ok.contains("❌"), ok)
    }

    test("SkyLight: every registered symbol resolves on this OS") {
        try expectEqual(SkyLight.missingSymbols(), [])
    }
}
