import AppKit
import CoreGraphics

// Polled window lifecycle: created / destroyed / titleChanged.
// Polling-based for v0 to avoid the AXObserver-per-app complexity. 1s tick
// is well within budget for UndoClose's use case (reopen recently closed)
// and any "recents" tracker. Architecturally identical fan-out to the
// AXObserver version — only the source of truth differs.
//
// Lazy: the 1Hz Timer only runs while at least one stack has subscribed
// (via subscribe(), typically because its manifest declares a sd.window.*
// handler). With no subscribers the daemon pays zero CPU here.
//
// AXObserver upgrade path is well-known if latency becomes an issue:
//   - per-pid AXObserver on kAXWindowCreatedNotification + per-window
//     observer on kAXUIElementDestroyedNotification & kAXTitleChangedNotification
//   - add/remove on NSWorkspace.{did{Launch,Terminate}Application}Notification
final class WindowsLifecycleObserver {
    static let shared = WindowsLifecycleObserver()

    struct Snap {
        let id: Int
        let pid: Int
        let app: String
        let title: String
        let frame: CGRect
    }

    var onCreate:       ((Snap) -> Void)?
    var onDestroy:      ((Snap) -> Void)?
    var onTitleChange:  ((Snap, String) -> Void)?  // (new, oldTitle)

    private var snapshot: [Int: Snap] = [:]
    private var timer: Timer?
    // Subscriber-count gate. Token cancel decrements; 1→0 stops the timer.
    // AppDelegate sets the callbacks once at startup; subscribers are added
    // by StackHost when a stack's manifest declares `handles: ["sd.window.*"]`.
    private var subCount: Int = 0

    private init() {}

    /// Each subscribe() increments the live-subscriber count; the returned
    /// Token decrements on cancel. Adopting into a Bridge.scope means stack
    /// unload automatically releases it. The 1Hz Timer only runs while
    /// subCount > 0.
    func subscribe() -> Token {
        subCount += 1
        if subCount == 1 { start() }
        var released = false
        return Token { [weak self] in
            guard let self = self, !released else { return }
            released = true
            self.subCount = max(0, self.subCount - 1)
            if self.subCount == 0 { self.stop() }
        }
    }

    private func start() {
        guard timer == nil else { return }
        snapshot = current()        // seed without firing on first tick
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        snapshot.removeAll()
    }

    private func tick() {
        let now = current()
        for (id, info) in now {
            if let old = snapshot[id] {
                if old.title != info.title { onTitleChange?(info, old.title) }
            } else {
                onCreate?(info)
            }
        }
        for (id, info) in snapshot where now[id] == nil {
            onDestroy?(info)
        }
        snapshot = now
    }

    /// JSON-able detail dict for bang dispatch.
    static func detail(_ s: Snap) -> [String: Any] {
        [
            "id":    s.id,
            "pid":   s.pid,
            "app":   s.app,
            "title": s.title,
            "frame": [
                "x": Int(s.frame.origin.x), "y": Int(s.frame.origin.y),
                "w": Int(s.frame.size.width), "h": Int(s.frame.size.height)
            ]
        ]
    }

    private func current() -> [Int: Snap] {
        var out: [Int: Snap] = [:]
        for raw in Windows.all() {
            guard let id = raw["id"] as? Int else { continue }
            let frameDict = raw["frame"] as? [String: Int] ?? [:]
            out[id] = Snap(
                id: id,
                pid: raw["pid"] as? Int ?? 0,
                app: raw["app"] as? String ?? "",
                title: raw["title"] as? String ?? "",
                frame: CGRect(
                    x: frameDict["x"] ?? 0, y: frameDict["y"] ?? 0,
                    width: frameDict["w"] ?? 0, height: frameDict["h"] ?? 0
                )
            )
        }
        return out
    }
}
