import Foundation

/// Pins `Permissions.all` as the single source of truth for every permission
/// stackd vends. `StackDoctor` and `ChannelInference` derive from it; the
/// `permission:` strings on `Bridge.primitives` are cross-validated here via
/// `Bridge.primitivePermissions`.
///
/// Same-commit guard for the doctor-allowlist rule in CLAUDE.md: a primitive
/// that ships with permission "foo" absent from `Permissions.all` fails the
/// first test below.
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

    test("no previously shipped permission has been dropped from the registry") {
        // Stacks in the wild declare these; removing one makes the doctor
        // flag a working manifest and stops inference from granting it.
        // Adding to the registry is fine.
        let shipped: Set<String> = [
            "battery", "mouse", "appearance", "caffeinate",
            "sensors", "location", "usb", "camera", "touchdevice", "displayLink",
            "app", "windows", "input", "net", "audio", "display", "media",
            "pasteboard", "apps", "spaces", "host", "calendar", "menubar", "privacy",
            "fs", "proc", "applescript", "notify", "settings", "defaults",
            "broadcasts", "ax", "spotlight", "speech", "vision", "nlp", "bonjour",
            "httpserver", "sqlite", "update", "cursor", "overlay", "shortcuts",
            "sound", "icons", "thumbnails", "events", "menu",
        ]
        let missingFromAll = shipped.union(["menubar.item"]).subtracting(Permissions.all)
        try expect(missingFromAll.isEmpty,
            "Permissions.all dropped shipped entries: \(missingFromAll.sorted())")
        let missingFromInferable = shipped.subtracting(Permissions.inferable)
        try expect(missingFromInferable.isEmpty,
            "Permissions.inferable dropped shipped entries: \(missingFromInferable.sorted())")
    }
}
