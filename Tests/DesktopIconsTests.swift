import Foundation

// Tests for `DesktopIcons` in Sources/DataSources/Desktop.swift — refcounted
// desktop-icon hiding through the WindowManager "Show Items: On Desktop"
// preference. The preference and the crash-recovery marker are in-memory
// stand-ins; nothing touches the live defaults or the filesystem.
func registerDesktopIconsTests() {
    final class Fake {
        var pref: Bool?
        var marker: DesktopIcons.Marker?
        var writes = 0
        init(pref: Bool?, marker: DesktopIcons.Marker? = nil) { self.pref = pref; self.marker = marker }
        func make() -> DesktopIcons {
            DesktopIcons(
                readHidden: { self.pref },
                writeHidden: { self.pref = $0; self.writes += 1 },
                loadMarker: { self.marker },
                saveMarker: { self.marker = $0 })
        }
    }

    test("DesktopIcons: hide sets the preference and records the prior value") {
        let f = Fake(pref: nil)
        let icons = f.make()
        let token = icons.hide()
        try expectEqual(f.pref, true)
        try expectEqual(f.marker, DesktopIcons.Marker(prior: nil))
        token.cancel()
        try expectEqual(f.pref, nil)
        try expect(f.marker == nil, "marker should clear once icons are restored")
    }

    test("DesktopIcons: icons stay hidden until the last holder releases") {
        let f = Fake(pref: false)
        let icons = f.make()
        let a = icons.hide(), b = icons.hide()
        try expectEqual(f.writes, 1)
        a.cancel()
        try expectEqual(f.pref, true)
        a.cancel()
        try expectEqual(f.pref, true, "double cancel must not release a second hold")
        b.cancel()
        try expectEqual(f.pref, false)
    }

    test("DesktopIcons: a value the user changed while hidden is left alone") {
        let f = Fake(pref: nil)
        let icons = f.make()
        let token = icons.hide()
        f.pref = false
        token.cancel()
        try expectEqual(f.pref, false)
        try expect(f.marker == nil, "marker should clear even when nothing is written")
    }

    test("DesktopIcons: launch recovery restores what a crashed daemon hid") {
        let f = Fake(pref: true, marker: DesktopIcons.Marker(prior: false))
        f.make().recoverOnLaunch()
        try expectEqual(f.pref, false)
        try expect(f.marker == nil, "marker should clear after recovery")

        let clean = Fake(pref: true)
        clean.make().recoverOnLaunch()
        try expectEqual(clean.pref, true, "no marker means the user hid the icons; keep them hidden")
        try expectEqual(clean.writes, 0)
    }

    test("DesktopIcons: releaseAll restores on shutdown") {
        let f = Fake(pref: nil)
        let icons = f.make()
        _ = icons.hide(); _ = icons.hide()
        icons.releaseAll()
        try expectEqual(f.pref, nil)
        try expect(f.marker == nil, "marker should clear on shutdown restore")
    }

    test("DesktopIcons: marker round-trips through JSON, including an unset prior") {
        for m in [DesktopIcons.Marker(prior: nil), DesktopIcons.Marker(prior: true), DesktopIcons.Marker(prior: false)] {
            let data = try JSONEncoder().encode(m)
            try expectEqual(try JSONDecoder().decode(DesktopIcons.Marker.self, from: data), m)
        }
    }
}
