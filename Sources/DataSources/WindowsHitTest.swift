import AppKit
import ApplicationServices

// sd.windows.at: the window a screen point lands on, and which part of it.
//
//   WindowHitTest — pure: front-to-back walk over CGWindowList rows, the
//                   resize-edge, title-bar and region rules.
//   WindowsByID.hitTest — impure: reads the rows on main, then asks the
//                   owning app over Accessibility on its AX queue.
//
// The rules follow what the window server and AppKit do with a click: a
// menu, panel or the Dock bar on top takes it; screen-sized overlays that
// let the mouse through (recorders, dimmers, the Dock's transparent layer)
// don't. The title bar is found from the close button, which AppKit centers
// vertically in the bar, and a point in it counts as `titlebar` only when
// every element from the hit up to the window is one that drags the window
// (a tab, button or field there is a `control`, and so is a web-drawn bar,
// whose parts Accessibility can't show drag the window). Idea credited to Wobbly
// (github.com/jsgrrchg/Wobbly); written from its description, not ported.

/// One CGWindowList row as the hit test sees it. `isOwn` marks one of
/// stackd's own windows that takes clicks (its click-through overlays are
/// left out of the rows before the hit test runs).
struct HitTestRow {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let frame: CGRect
    let owner: String
    let bundleID: String?
    let isOwn: Bool
}

enum WindowEdge: String {
    case left, top, right, bottom
}

enum HitRegion: String {
    case edge, titlebar, control, content
}

enum WindowHitTest {
    /// How far from a window's edge, inside or out, a press resizes it.
    static let resizeBorder: CGFloat = 5

    /// Recorders whose overlays (region border, click rings, camera) sit on
    /// top without taking clicks. Bundle ids, since owner names are localized.
    static let captureOverlayBundleIDs: Set<String> = [
        "com.apple.screencaptureui", "pl.maketheweb.cleanshotx", "com.wulkano.kap", "com.loom.desktop",
        "com.obsproject.obs-studio", "so.screen.studio", "net.telestream.screenflow10",
    ]
    /// Owners with no bundle that overlay the same way.
    static let captureOverlayOwners: Set<String> = ["screencapture"]
    /// Screen-sized layers that do take clicks.
    static let blockingOwners: Set<String> = ["loginwindow", "ScreenSaverEngine"]
    /// Elements a press on drags the window instead of acting on.
    static let draggableRoles: Set<String> = ["AXWindow", "AXToolbar", "AXGroup", "AXStaticText"]

    /// The frontmost normal (layer 0) window whose frame, grown by the resize
    /// border, holds `point`; nil when nothing is there or something that
    /// takes the click covers it first. `rows` run front to back. `dockBar`
    /// is asked only when the Dock's screen layer is in the way.
    static func topWindow(rows: [HitTestRow], at point: CGPoint, screens: [CGRect],
                          dockBar: () -> CGRect?) -> HitTestRow? {
        for row in rows {
            guard row.frame.insetBy(dx: -resizeBorder, dy: -resizeBorder).contains(point),
                  row.alpha >= 0.01 else { continue }
            if row.isOwn { return nil }
            if row.layer == 0 { return row }
            guard passesClicks(row, at: point, screens: screens, dockBar: dockBar) else { return nil }
        }
        return nil
    }

    private static func passesClicks(_ row: HitTestRow, at point: CGPoint, screens: [CGRect],
                                     dockBar: () -> CGRect?) -> Bool {
        if blockingOwners.contains(row.owner) { return false }
        // While recording, the window server draws the cursor and its
        // indicators as small windows of its own. The menu bar is its too.
        if row.owner == "Window Server" { return row.frame.width <= 128 && row.frame.height <= 128 }
        if row.owner == "Dock" {
            // A visible Dock lays a transparent screen-sized layer at the Dock
            // level that only takes clicks over the bar. Mission Control and
            // Launchpad use other levels.
            return row.layer == Int(CGWindowLevelForKey(.dockWindow))
                && coverage(of: row.frame, screens: screens) >= 0.9
                && !(dockBar()?.contains(point) ?? true)
        }
        if captureOverlayOwners.contains(row.owner) { return true }
        if let bundleID = row.bundleID, captureOverlayBundleIDs.contains(bundleID) { return true }
        return coverage(of: row.frame, screens: screens) >= 0.9
    }

    /// The largest share of any one screen `frame` covers.
    private static func coverage(of frame: CGRect, screens: [CGRect]) -> CGFloat {
        screens.map { screen in
            let overlap = screen.intersection(frame)
            return overlap.isNull ? 0 : (overlap.width * overlap.height) / (screen.width * screen.height)
        }.max() ?? 0
    }

    /// The edges whose resize zone holds `point`, whether or not the app lets
    /// the window resize. A corner names two.
    static func edges(of frame: CGRect, at point: CGPoint) -> [WindowEdge] {
        guard frame.insetBy(dx: -resizeBorder, dy: -resizeBorder).contains(point) else { return [] }
        var out: [WindowEdge] = []
        if abs(point.x - frame.minX) <= resizeBorder { out.append(.left) }
        if abs(point.y - frame.minY) <= resizeBorder { out.append(.top) }
        if abs(point.x - frame.maxX) <= resizeBorder { out.append(.right) }
        if abs(point.y - frame.maxY) <= resizeBorder { out.append(.bottom) }
        return out
    }

    /// Height of the title bar of the window at `frame`, from its close
    /// button's center; nil when the button isn't in the window or the
    /// height is out of any real bar's range.
    static func titleBarHeight(frame: CGRect, closeButton: CGRect) -> CGFloat? {
        let center = CGPoint(x: closeButton.midX, y: closeButton.midY)
        guard frame.contains(center) else { return nil }
        let height = 2 * (center.y - frame.minY)
        return (20...120).contains(height) ? height : nil
    }

    /// True when `roles`, read from the hit element up through its parents,
    /// reaches the window through draggable elements only.
    static func isDraggable(roles: [String]) -> Bool {
        guard roles.last == "AXWindow" else { return false }
        return roles.allSatisfy { draggableRoles.contains($0) }
    }

    static func region(frame: CGRect, point: CGPoint, titleBarHeight: CGFloat?, draggable: Bool) -> HitRegion {
        if !edges(of: frame, at: point).isEmpty { return .edge }
        if let bar = titleBarHeight, point.y - frame.minY <= bar { return draggable ? .titlebar : .control }
        return .content
    }
}

extension WindowsByID {
    /// The longest walk from the hit element up to its window.
    private static let hitWalkLimit = 8

    /// sd.windows.at. Reads the window list on main, then asks the owning
    /// app on its AX queue (0.1s cap per read), and calls `completion` on
    /// main with { id, pid, app, frame, region, edges } or nil. Main thread.
    static func hitTest(at point: CGPoint, completion: @escaping ([String: Any]?) -> Void) {
        guard let row = WindowHitTest.topWindow(rows: hitTestRows(), at: point, screens: displayBounds(),
                                                dockBar: DockBar.frame) else {
            completion(nil)
            return
        }
        AXAppQueues.queue(for: row.pid).async {
            let (region, edges) = hitRegion(of: row, at: point)
            DispatchQueue.main.async { completion(hitPayload(row, region: region, edges: edges)) }
        }
    }

    /// Which part of `row`'s window `point` is on, with the edges for an
    /// `edge`. Only a point off the edges asks the app. Any thread; the
    /// app's AX queue in production.
    static func hitRegion(of row: HitTestRow, at point: CGPoint) -> (HitRegion, [WindowEdge]) {
        let edges = WindowHitTest.edges(of: row.frame, at: point)
        guard edges.isEmpty else { return (.edge, edges) }
        let (bar, draggable) = titleBar(of: row, at: point)
        return (WindowHitTest.region(frame: row.frame, point: point, titleBarHeight: bar, draggable: draggable), [])
    }

    private static func hitPayload(_ row: HitTestRow, region: HitRegion, edges: [WindowEdge]) -> [String: Any] {
        [
            "id": Int(row.id), "pid": Int(row.pid), "app": row.owner,
            "frame": ["x": Double(row.frame.minX), "y": Double(row.frame.minY),
                      "w": Double(row.frame.width), "h": Double(row.frame.height)],
            "region": region.rawValue,
            "edges": edges.map(\.rawValue),
        ]
    }

    /// On-screen rows front to back, without stackd's click-through overlays.
    /// Main thread (reads NSApp.windows).
    private static func hitTestRows() -> [HitTestRow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let clickThrough = Set(((NSApp as NSApplication?)?.windows ?? []).filter { $0.ignoresMouseEvents }.map { CGWindowID($0.windowNumber) })
        var bundleIDs: [pid_t: String?] = [:]
        return raw.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let id = CGWindowID(number)
            let isOwn = pid == ownPid
            if isOwn && clickThrough.contains(id) { return nil }
            if bundleIDs[pid] == nil {
                bundleIDs[pid] = .some(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            }
            return HitTestRow(id: id, pid: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0,
                              alpha: info[kCGWindowAlpha as String] as? Double ?? 1, frame: frame,
                              owner: info[kCGWindowOwnerName as String] as? String ?? "",
                              bundleID: bundleIDs[pid] ?? nil, isOwn: isOwn)
        }
    }

    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// The title bar height of `row`'s window and whether `point` is on a
    /// draggable part of it, asking the owning app rather than the system-wide
    /// element so other apps' transparent layers don't answer instead. Runs
    /// on the app's AX queue.
    private static func titleBar(of row: HitTestRow, at point: CGPoint) -> (CGFloat?, Bool) {
        let app = AX.appElement(pid: row.pid, timeout: 0.1)
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hitRef) == .success,
              let hit = hitRef.map({ AX.bounded($0, 0.1) }) else { return (nil, false) }
        // Walk up while every element drags the window: the first one that
        // doesn't (or a tree deeper than the limit, like a web-drawn title
        // bar's) settles "not draggable", and the window then comes from the
        // hit's own AXWindow attribute.
        var roles: [String] = []
        var walked: AXUIElement?
        var current: AXUIElement? = hit
        while let el = current, roles.count < hitWalkLimit {
            let role = AX.string(of: el, kAXRoleAttribute) ?? ""
            roles.append(role)
            if role == kAXWindowRole as String {
                walked = el
                break
            }
            guard WindowHitTest.draggableRoles.contains(role) else { break }
            current = AX.element(of: el, kAXParentAttribute, timeout: 0.1)
        }
        // The hit may sit in a sheet or child window: only the row's own
        // window has the title bar we measure.
        guard let window = walked ?? AX.element(of: hit, kAXWindowAttribute, timeout: 0.1),
              let getWindow = AXShim.getWindow else { return (nil, false) }
        var wid: CGWindowID = 0
        guard getWindow(window, &wid) == .success, wid == row.id,
              let close = AX.element(of: window, kAXCloseButtonAttribute, timeout: 0.1),
              let closeFrame = WindowAXRead.frame(of: close) else { return (nil, false) }
        return (WindowHitTest.titleBarHeight(frame: row.frame, closeButton: closeFrame),
                WindowHitTest.isDraggable(roles: roles))
    }
}

/// Where the Dock bar is, read from the Dock over Accessibility and kept for
/// half a second (the hit test may ask on every click). Main thread.
private enum DockBar {
    private static var cached: (frame: CGRect?, at: CFTimeInterval)?

    static func frame() -> CGRect? {
        let now = CACurrentMediaTime()
        if let cached, now - cached.at <= 0.5 { return cached.frame }
        let frame = read()
        cached = (frame, now)
        return frame
    }

    private static func read() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let lists = AX.children(of: AX.appElement(pid: dock.processIdentifier, timeout: 0.05), timeout: 0.05)
            .filter { AX.string(of: $0, kAXRoleAttribute) == kAXListRole as String }
        let frames = lists.compactMap(WindowAXRead.frame(of:))
        return frames.isEmpty ? nil : frames.reduce(CGRect.null) { $0.union($1) }
    }
}
