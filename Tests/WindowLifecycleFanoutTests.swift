import AppKit
import CoreGraphics
import Foundation

// Characterization of `WindowLifecycleFanout.fireCreated` in
// `Sources/DataSources/WindowsLifecycle.swift`: the order stacks observe for
// a window create. The sd.windows.all push lands before the
// sd.window.created bang (a stack diffing the list must already hold the
// window when the bang arrives), each window is announced once per TTL
// whichever announcer calls first, and a window CGWindowList never lists is
// still announced once the re-check ladder runs out. The host is a recorder,
// so no stack receives anything.

private final class RecordingHost: WindowLifecycleHost {
    var events: [String] = []
    var createdIDs: [Int] = []

    func pumpWindowsListForAllStacks() { events.append("pump") }

    func bang(name: String, detail: [String: Any]) -> Int {
        events.append(name)
        if let id = detail["id"] as? Int { createdIDs.append(id) }
        return 0
    }
}

private func snap(_ id: Int, pid: Int = 7_777_740) -> WindowsLifecycleObserver.Snap {
    WindowsLifecycleObserver.Snap(id: id, pid: pid, app: "App", title: "T",
                                  frame: CGRect(x: 0, y: 0, width: 100, height: 100))
}

func registerWindowLifecycleFanoutTests() {
    test("created fan-out: a window the list never shows is announced after the ladder, pump before bang, once") {
        let host = RecordingHost()
        let id = 4_294_000_101
        WindowLifecycleFanout.fireCreated(host: host, snap: snap(id))
        WindowLifecycleFanout.fireCreated(host: host, snap: snap(id))
        try expectEqual(host.events, [], "an unlisted window waits on the re-check ladder")
        try expect(WindowLifecycleFanout.announcedRecently(id: id), "the announcement is marked at the first call")
        let ladder = WindowsPumpRetry.delays.reduce(0, +)
        try expect(spin(timeout: ladder + 10) { host.events.count >= 2 }, "never announced")
        drainMainQueue()
        try expectEqual(host.events, ["pump", "sd.window.created"])
        try expectEqual(host.createdIDs, [id])
    }

    test("created fan-out: a window the list already shows is announced at once, pump before bang") {
        // A real app window, made to read standard so Windows.all() lists it.
        let ownPid = Int(ProcessInfo.processInfo.processIdentifier)
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard let row = rows.first(where: {
            ($0[kCGWindowLayer as String] as? Int).map(Windows.isAppWindowLevel) == true
                && ($0[kCGWindowOwnerPID as String] as? Int).map { $0 != ownPid } == true
                && $0[kCGWindowOwnerName as String] is String && $0[kCGWindowBounds as String] != nil
        }),
              let id = row[kCGWindowNumber as String] as? Int,
              let pid = row[kCGWindowOwnerPID as String] as? Int,
              !WindowLifecycleFanout.announcedRecently(id: id)
        else { return }   // no app window in this session
        WindowAddressabilityCache.confirm(pid: pid_t(pid), windowID: CGWindowID(id), isStandard: true, isMinimized: false)
        defer { WindowAddressabilityCache.invalidate(pid: pid_t(pid), windowID: CGWindowID(id)) }
        let host = RecordingHost()
        WindowLifecycleFanout.fireCreated(host: host, snap: snap(id, pid: pid))
        try expectEqual(host.events, ["pump", "sd.window.created"])
        WindowLifecycleFanout.fireCreated(host: host, snap: snap(id, pid: pid))
        try expectEqual(host.events, ["pump", "sd.window.created"], "a second announcer is deduped")
    }
}
