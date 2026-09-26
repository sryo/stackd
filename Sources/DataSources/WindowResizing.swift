import AppKit
import CoreGraphics

// =====================================================================
// MARK: - User-driven resize (sd.window.resizing)
// =====================================================================

/// Pure state machine behind `sd.window.resizing`. Fed one frame per
/// drained window-server frame event (806/807 merged per window), it
/// decides when a user drag of a window edge begins, changes and ends.
///
/// The begin/end sources are inputs, not baked in: `interacting` gates
/// begins (today the left mouse button; the window-drag codes 1411/1412
/// could stand in for it) and `release` ends every active drag (today a
/// left mouse-up; 1412 could call it just as well). `expireQuiet` is the
/// fallback when the release is missed.
///
/// - begin: the first size change of a window, relative to the last frame
///   seen for it, while interacting and not an echo of a daemon write.
///   One user drag at a time: a mouse resizes one window, so a second
///   window's size change during a drag is a stack writing its neighbor.
/// - change: every later frame that differs from the last one reported.
///   The echo gate applies to the begin only; once a drag is live the
///   window is under the user's hand and its frames are the truth.
/// - end: on `release`, or after `quietInterval` without frames while not
///   interacting.
struct WindowResizeTracker {
    enum Phase: String {
        case began, changed, ended
    }

    /// Which edges moved from the drag's start frame.
    struct Edges: Equatable {
        var left: Bool
        var right: Bool
        var top: Bool
        var bottom: Bool
    }

    struct Event: Equatable {
        let id: UInt32
        let phase: Phase
        let frame: CGRect
        let startFrame: CGRect
        let edges: Edges

        var payload: [String: Any] {
            func rect(_ r: CGRect) -> [String: Int] {
                ["x": Int(r.origin.x.rounded()), "y": Int(r.origin.y.rounded()),
                 "w": Int(r.size.width.rounded()), "h": Int(r.size.height.rounded())]
            }
            return [
                "id": Int(id),
                "phase": phase.rawValue,
                "frame": rect(frame),
                "startFrame": rect(startFrame),
                "edges": ["left": edges.left, "right": edges.right,
                          "top": edges.top, "bottom": edges.bottom],
            ]
        }
    }

    static let quietInterval: Double = 0.15
    /// Sub-point differences are rounding, not movement.
    static let tolerance: CGFloat = 0.5

    private struct Drag {
        let startFrame: CGRect
        var frame: CGRect
        var lastFrameAt: Double
    }

    private var known: [UInt32: CGRect] = [:]
    private var drags: [UInt32: Drag] = [:]

    var isActive: Bool { !drags.isEmpty }
    var activeIDs: [UInt32] { drags.keys.sorted() }

    static func edges(from start: CGRect, to frame: CGRect) -> Edges {
        func moved(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > tolerance }
        return Edges(left: moved(start.minX, frame.minX),
                     right: moved(start.maxX, frame.maxX),
                     top: moved(start.minY, frame.minY),
                     bottom: moved(start.maxY, frame.maxY))
    }

    private static func sameSize(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        sameSize(a, b) && abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
    }

    mutating func observe(id: UInt32, frame: CGRect, interacting: Bool,
                          isSelf: Bool, now: Double) -> Event? {
        let prior = known[id]
        known[id] = frame
        if var drag = drags[id] {
            drag.lastFrameAt = now
            defer { drags[id] = drag }
            guard !Self.sameFrame(drag.frame, frame) else { return nil }
            drag.frame = frame
            return Event(id: id, phase: .changed, frame: frame, startFrame: drag.startFrame,
                         edges: Self.edges(from: drag.startFrame, to: frame))
        }
        guard interacting, !isSelf, drags.isEmpty,
              let start = prior, !Self.sameSize(start, frame) else { return nil }
        drags[id] = Drag(startFrame: start, frame: frame, lastFrameAt: now)
        return Event(id: id, phase: .began, frame: frame, startFrame: start,
                     edges: Self.edges(from: start, to: frame))
    }

    /// The interaction ended: every active drag ends, at the frame in
    /// `frames` (read at release time) or else the last one seen.
    mutating func release(frames: [UInt32: CGRect]) -> [Event] {
        let ended = drags.keys.sorted().map { end($0, at: frames[$0]) }
        return ended
    }

    /// Drags with no frame for `quietInterval` end, unless the user is
    /// still interacting (holding the edge still).
    mutating func expireQuiet(now: Double, interacting: Bool) -> [Event] {
        guard !interacting else { return [] }
        return drags.filter { now - $0.value.lastFrameAt >= Self.quietInterval }
            .keys.sorted().map { end($0, at: nil) }
    }

    /// The window is gone: drop its drag and baseline without an event.
    mutating func forget(id: UInt32) {
        drags[id] = nil
        known[id] = nil
    }

    private mutating func end(_ id: UInt32, at frame: CGRect?) -> Event {
        let drag = drags.removeValue(forKey: id)!
        let final = frame ?? drag.frame
        known[id] = final
        return Event(id: id, phase: .ended, frame: final, startFrame: drag.startFrame,
                     edges: Self.edges(from: drag.startFrame, to: final))
    }
}

/// Impure shell: feeds WindowResizeTracker from the intake's frame events
/// for AX-tracked windows and fires `sd.window.resizing`. The left button
/// state (CGEventSourceButtonState) gates begins; a left mouse-up from the
/// shared CGEventTap, held only while a drag is live, ends them. When the
/// tap is unavailable (Accessibility denied) a one-shot check after
/// `quietInterval` ends drags whose button is up, re-arming only while the
/// button is still held. Main thread only.
final class WindowResizeObserver {
    static let shared = WindowResizeObserver()
    private init() {}

    static let bangName = "sd.window.resizing"

    private var tracker = WindowResizeTracker()
    private var mouseUpToken: Token?
    private var quietCheckQueued = false

    /// A drained 806/807 for `wid`.
    func frameEvent(wid: CGWindowID, host: StackHost) {
        // Nothing to do (not even a bounds read) while no stack listens.
        guard tracker.isActive || host.anyHandles(bang: Self.bangName) else { return }
        guard WindowsAXObserver.shared.pidFor(wid: wid) != nil,
              let frame = Overlay.bounds(of: wid) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let interacting = Mouse.isLeftButtonDown()
        // The ledger lookup only matters for a begin.
        let isSelf = !tracker.isActive && interacting
            && FrameLedger.shared.isSelf(windowID: wid, observed: frame, now: now)
        guard let event = tracker.observe(id: UInt32(wid), frame: frame, interacting: interacting,
                                          isSelf: isSelf, now: now) else { return }
        emit([event], host: host)
    }

    func windowDestroyed(wid: CGWindowID) {
        tracker.forget(id: UInt32(wid))
        syncReleaseSources()
    }

    private func release() {
        guard let host = AppDelegate.shared?.host else { return }
        var frames: [UInt32: CGRect] = [:]
        for id in tracker.activeIDs {
            frames[id] = Overlay.bounds(of: CGWindowID(id))
        }
        emit(tracker.release(frames: frames), host: host)
    }

    private func emit(_ events: [WindowResizeTracker.Event], host: StackHost) {
        for e in events {
            WindowDebug.log("resizing: wid=\(e.id) \(e.phase.rawValue) frame=\(e.frame)")
            host.bang(name: Self.bangName, detail: e.payload)
        }
        syncReleaseSources()
    }

    private func syncReleaseSources() {
        guard tracker.isActive else {
            mouseUpToken?.cancel()
            mouseUpToken = nil
            return
        }
        if mouseUpToken == nil {
            mouseUpToken = EventTapRegistry.shared.register(eventType: .leftMouseUp) { [weak self] _, _ in
                self?.release()
            }
        }
        scheduleQuietCheck()
    }

    private func scheduleQuietCheck() {
        guard !quietCheckQueued else { return }
        quietCheckQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowResizeTracker.quietInterval) { [weak self] in
            guard let self = self else { return }
            self.quietCheckQueued = false
            guard self.tracker.isActive, let host = AppDelegate.shared?.host else { return }
            let buttonDown = Mouse.isLeftButtonDown()
            let ended = self.tracker.expireQuiet(now: CFAbsoluteTimeGetCurrent(), interacting: buttonDown)
            if !ended.isEmpty {
                self.emit(ended, host: host)
            } else if !buttonDown || self.mouseUpToken == nil {
                // Button up but not quiet long enough yet, or no tap to
                // deliver the mouse-up: check again. A held button with
                // the tap installed waits for the mouse-up instead.
                self.scheduleQuietCheck()
            }
        }
    }
}
