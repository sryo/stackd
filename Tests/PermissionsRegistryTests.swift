import Foundation

/// Pins `Permissions.all` as the single source of truth for every permission
/// stackd vends. Before A2, three lists drifted:
///
///   1. `StackDoctor.known` (Sources/StackTemplates.swift)
///   2. `ChannelInference.topLevelChannels` (Sources/StackSource.swift)
///   3. The `permission:` strings buried in `Bridge.primitives`
///
/// After A2, the first two derive from `Permissions.all` / `Permissions.inferable`
/// directly, and these tests cross-validate the third by walking
/// `Bridge.primitivePermissions` against the canonical registry.
///
/// The drift-prevention contract: if a primitive ships with permission
/// "foo" that isn't in `Permissions.all`, the "every primitive permission
/// is in Permissions.all" test fails. Same-commit guard for the
/// doctor-allowlist rule in CLAUDE.md.
func registerPermissionsRegistryTests() {
    test("every Bridge primitive permission is in Permissions.all") {
        // The headline cross-validation. Each .sync / .custom / .ax /
        // .syncBridge declaration's `permission:` string must resolve to
        // an entry in Permissions.all. If this fails, a new primitive
        // landed without the registry entry — fix by adding the missing
        // string to Permissions.all (and ideally to Permissions.inferable
        // if the namespace mirrors the permission name).
        let missing = Bridge.primitivePermissions.subtracting(Permissions.all)
        try expect(missing.isEmpty,
            "Bridge.primitives declares permissions absent from Permissions.all: \(missing.sorted())")
    }

    test("Permissions.inferable is a subset of Permissions.all") {
        // Sanity: inference can't auto-add a permission the doctor rejects.
        // If this fails, `Permissions.inferable` was constructed wrong (the
        // definition uses `all.subtracting(...)` so this should be provable
        // by construction, but the test pins the invariant).
        let extra = Permissions.inferable.subtracting(Permissions.all)
        try expect(extra.isEmpty,
            "Permissions.inferable has entries not in Permissions.all: \(extra.sorted())")
    }

    test("composite permissions are NOT inferable") {
        // `menubar.item` and any other composite must stay out of the
        // auto-inference path. Composites have stricter side-effects than
        // their base namespace and need explicit manifest opt-in.
        try expect(!Permissions.inferable.contains("menubar.item"),
            "menubar.item leaked into inferable set — composites must require explicit opt-in")
    }

    test("StackDoctor accepts every permission in Permissions.all") {
        // Whole-pipeline check: feed each registry entry through the doctor
        // and assert it's accepted. Catches the bug where someone narrows
        // the doctor's allowlist filter without touching the registry.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        // Build one manifest declaring every known permission.
        let dir = parent.appendingPathComponent("allperms").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let permsJSON = Permissions.all.sorted()
            .map { "\"\($0)\"" }.joined(separator: ", ")
        let stackJSON = """
        { "id": "allperms", "name": "allperms", "size": {"h": 24},
          "permissions": [\(permsJSON)] }
        """
        try? stackJSON.write(toFile: dir + "/stack.json", atomically: true, encoding: .utf8)
        try? "<div/>".write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
        try expectEqual(StackDoctor.check(stackDir: dir), 0)
    }

    test("ChannelInference infers every inferable permission from sd.<name>.* text") {
        // For each inferable permission, build a minimal source blob that
        // mentions `sd.<perm>.x` and confirm inference picks it up. Catches
        // typos that would make a permission silently uninferred (e.g. a
        // boundary-check regression).
        for perm in Permissions.inferable {
            let src = "sd.\(perm).x"
            let got = ChannelInference.infer(from: src)
            try expect(got.contains(perm),
                "ChannelInference failed to infer '\(perm)' from \(src.debugDescription) (got \(got.sorted()))")
        }
    }

    test("Permissions.all is a strict superset of pre-A2 StackDoctor allowlist") {
        // Snapshot of the pre-refactor `known` set in StackTemplates.swift.
        // Adding to the registry is fine; shrinking below this set means a
        // previously-accepted permission would start triggering the doctor
        // warning. Catches accidental deletes.
        let preRefactor: Set<String> = [
            "battery", "mouse", "appearance", "input", "net", "audio", "display",
            "media", "settings", "fs", "pasteboard", "proc", "events", "apps",
            "icons", "ax", "windows", "spaces", "menubar", "menubar.item", "menu",
            "app", "defaults", "caffeinate", "notify", "location", "usb",
            "camera", "broadcasts", "host", "applescript", "sound", "nlp",
            "touchdevice", "displayLink", "httpserver", "vision", "sqlite",
            "cursor", "overlay", "shortcuts",
            "spotlight", "speech", "calendar", "thumbnails", "update",
            "bonjour", "privacy"
        ]
        let missing = preRefactor.subtracting(Permissions.all)
        try expect(missing.isEmpty,
            "Permissions.all dropped pre-A2 entries: \(missing.sorted())")
    }

    test("Permissions.all is a strict superset of pre-A2 ChannelInference list") {
        let preRefactor: Set<String> = [
            "battery", "mouse", "appearance", "caffeinate",
            "sensors", "location", "usb", "camera", "touchdevice", "displayLink",
            "app", "windows", "input", "net", "audio", "display", "media",
            "pasteboard", "apps", "spaces", "host", "calendar", "menubar", "privacy",
            "fs", "proc", "applescript", "notify", "settings", "defaults",
            "broadcasts", "ax", "spotlight", "speech", "vision", "nlp", "bonjour",
            "httpserver", "sqlite", "update", "cursor", "overlay", "shortcuts",
            "sound", "icons", "thumbnails", "events", "menu"
        ]
        let missing = preRefactor.subtracting(Permissions.inferable)
        try expect(missing.isEmpty,
            "Permissions.inferable dropped pre-A2 entries: \(missing.sorted())")
    }
}
