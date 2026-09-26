import Foundation

/// `sd.desktop` — desktop-icon visibility. Holds stack LIFO on
/// `desktopIconHolds`; the scope drain in Bridge.swift releases whatever a
/// stack leaves behind at unload.
extension Bridge {
    static func desktopPrimitives() -> [Primitive] {
        return [
            .syncBridge("desktop.hideIcons", permission: "desktop", denyValue: false) { bridge, _ in
                bridge.desktopIconHolds.append(DesktopIcons.shared.hide())
                return true
            },
            .syncBridge("desktop.showIcons", permission: "desktop", denyValue: false) { bridge, _ in
                guard let t = bridge.desktopIconHolds.popLast() else { return false }
                t.cancel(); return true
            },
        ]
    }
}
