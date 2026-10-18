import Carbon.HIToolbox
import Foundation

// Hotkey specs ("ctrl+alt+cmd+b") and the gate a firing hotkey passes before
// its callback runs. Nothing here registers a Carbon hot key.

func registerHotkeyTests() {
    let cmd = UInt32(cmdKey), ctrl = UInt32(controlKey), opt = UInt32(optionKey), shift = UInt32(shiftKey)

    func parsed(_ spec: String) -> HotkeySpec? {
        if case .success(let s) = HotkeySpec.parse(spec) { return s }
        return nil
    }

    func failure(_ spec: String) -> HotkeySpec.ParseError? {
        if case .failure(let e) = HotkeySpec.parse(spec) { return e }
        return nil
    }

    // MARK: - HotkeySpec.parse

    test("HotkeySpec.parse: modifiers accumulate and the last token is the key") {
        let s = parsed("ctrl+alt+cmd+b")
        try expectEqual(s?.keyCode, UInt32(kVK_ANSI_B))
        try expectEqual(s?.modifiers, ctrl | opt | cmd)
    }

    test("HotkeySpec.parse: modifier aliases, case and spacing are forgiven") {
        let s = parsed(" Command + Control + OPT + Shift + A ")
        try expectEqual(s?.keyCode, UInt32(kVK_ANSI_A))
        try expectEqual(s?.modifiers, cmd | ctrl | opt | shift)
        try expectEqual(parsed("meta+option+x")?.modifiers, cmd | opt)
    }

    test("HotkeySpec.parse: a bare key carries no modifiers") {
        let s = parsed("space")
        try expectEqual(s?.keyCode, UInt32(kVK_Space))
        try expectEqual(s?.modifiers, 0)
    }

    test("HotkeySpec.parse: fn is rejected instead of binding the bare key") {
        try expectEqual(failure("fn+x"), .unsupportedModifier("fn"))
        try expectEqual(failure("cmd+fn+left"), .unsupportedModifier("fn"))
        try expectEqual(failure("fn"), .unsupportedModifier("fn"))
    }

    test("HotkeySpec.parse: a spec without a key is rejected") {
        try expectEqual(failure("cmd+shift"), .missingKey)
        try expectEqual(failure(""), .missingKey)
    }

    test("HotkeySpec.parse: an unknown key is rejected by name") {
        try expectEqual(failure("cmd+lolnotakey"), .unknownKey("lolnotakey"))
    }

    test("HotkeySpec.parse: function keys can be bound") {
        try expectEqual(parsed("f5")?.keyCode, UInt32(kVK_F5))
        try expectEqual(parsed("cmd+shift+f12")?.keyCode, UInt32(kVK_F12))
        try expectEqual(parsed("ctrl+f20")?.keyCode, UInt32(kVK_F20))
    }

    // MARK: - HotkeyRegistry.keyCode

    test("HotkeyRegistry.keyCode: navigation cluster and keypad resolve from the one table") {
        try expectEqual(HotkeyRegistry.keyCode(for: "home"), UInt32(kVK_Home))
        try expectEqual(HotkeyRegistry.keyCode(for: "pagedown"), UInt32(kVK_PageDown))
        try expectEqual(HotkeyRegistry.keyCode(for: "forwarddelete"), UInt32(kVK_ForwardDelete))
        try expectEqual(HotkeyRegistry.keyCode(for: "pad5"), UInt32(kVK_ANSI_Keypad5))
        try expectEqual(HotkeyRegistry.keyCode(for: "padplus"), UInt32(kVK_ANSI_KeypadPlus))
        try expectEqual(HotkeyRegistry.keyCode(for: "pad+"), UInt32(kVK_ANSI_KeypadPlus))
    }

    test("HotkeyRegistry.keyCode: f1 through f20 and the keypad digits each resolve to their own key") {
        let names = (1...20).map { "f\($0)" } + (0...9).map { "pad\($0)" }
        let codes = names.compactMap { HotkeyRegistry.keyCode(for: $0) }
        try expectEqual(codes.count, names.count)
        try expectEqual(Set(codes).count, names.count, "no two names share a keycode")
    }

    // MARK: - HotkeyRegistry.gateAllows

    func gate(mode: String? = nil, current: String = "default", apps: [String]? = nil,
              exclude: [String]? = nil, front: String = "com.example.front") -> (allowed: Bool, lookups: Int) {
        var lookups = 0
        let allowed = HotkeyRegistry.gateAllows(
            mode: mode, currentMode: current, apps: apps, excludeApps: exclude,
            frontmost: { lookups += 1; return front })
        return (allowed, lookups)
    }

    test("hotkey gate: an ungated binding fires without looking up the frontmost app") {
        let r = gate()
        try expect(r.allowed)
        try expectEqual(r.lookups, 0)
    }

    test("hotkey gate: a wildcard app list is ungated too") {
        let r = gate(apps: ["*"])
        try expect(r.allowed)
        try expectEqual(r.lookups, 0)
    }

    test("hotkey gate: a mode other than the active one blocks without a lookup") {
        let r = gate(mode: "command", current: "default", apps: ["com.example.front"])
        try expect(!r.allowed)
        try expectEqual(r.lookups, 0)
        try expect(gate(mode: "command", current: "command").allowed)
    }

    test("hotkey gate: the app list admits only the listed frontmost app") {
        try expect(gate(apps: ["com.example.front"]).allowed)
        try expect(!gate(apps: ["com.example.other"]).allowed)
        try expectEqual(gate(apps: ["com.example.other"]).lookups, 1)
    }

    test("hotkey gate: the exclusion list blocks a listed frontmost app") {
        try expect(!gate(exclude: ["com.example.front"]).allowed)
        try expect(gate(exclude: ["com.example.other"]).allowed)
    }

    test("hotkey gate: an app list and an exclusion list must both pass, with one lookup") {
        let r = gate(apps: ["com.example.front"], exclude: ["com.example.front"])
        try expect(!r.allowed)
        try expectEqual(r.lookups, 1)
    }
}
