import AppKit

// Tests for `MenuSpec` in Sources/DataSources/Menubar.swift: the NSMenu
// built from a declarative item list, shared by status-item menus
// (sd.menubar.addItem / item.setMenu) and the cursor popup (sd.menu.popup).
// The menus are built and inspected, never shown.

private final class PickTarget: NSObject {
    @objc func pick(_ sender: NSMenuItem) {}
}

func registerMenuSpecTests() {
    let target = PickTarget()
    let action = #selector(PickTarget.pick(_:))

    test("MenuSpec: enabled:false stays disabled once AppKit validates the menu") {
        let menu = MenuSpec.menu([
            ["id": "on", "title": "On"],
            ["id": "off", "title": "Off", "enabled": false],
        ], target: target, action: action)
        // update() runs the validation a menu gets right before it opens.
        menu.update()
        try expectEqual(menu.items.map(\.isEnabled), [true, false])
    }

    test("MenuSpec: enabled:false inside a submenu stays disabled too") {
        let menu = MenuSpec.menu([
            ["title": "More", "submenu": [
                ["id": "a", "title": "A"],
                ["id": "b", "title": "B", "enabled": false],
            ]],
        ], target: target, action: action)
        let sub = try unwrap(menu.items.first?.submenu)
        sub.update()
        try expectEqual(sub.items.map(\.isEnabled), [true, false])
    }

    test("MenuSpec: items carry their id, title and check state, and pick through the target") {
        let menu = MenuSpec.menu([
            ["id": "x", "title": "X", "checked": true],
            ["separator": true],
            ["id": "y", "title": "Y", "checked": false],
        ], target: target, action: action)
        try expectEqual(menu.items.count, 3)
        let x = menu.items[0], sep = menu.items[1], y = menu.items[2]
        try expectEqual(x.title, "X")
        try expectEqual(x.representedObject as? String, "x")
        try expectEqual(x.state, .on)
        try expect(x.target === target && x.action == action, "an item picks through the target")
        try expect(sep.isSeparatorItem)
        try expectEqual(y.state, .off)
        try expectEqual(y.representedObject as? String, "y")
    }

    test("MenuSpec: a submenu item opens its children, which pick through the target") {
        let menu = MenuSpec.menu([
            ["title": "More", "submenu": [["id": "deep", "title": "Deep"]]],
        ], target: target, action: action)
        let parent = menu.items[0]
        let sub = try unwrap(parent.submenu)
        try expectEqual(parent.title, "More")
        try expectEqual(sub.items.map { $0.representedObject as? String }, ["deep"])
        try expect(sub.items[0].target === target && sub.items[0].action == action)
    }
}

private func unwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    try expect(value != nil, "expected a value", file: file, line: line)
    return value!
}
