import Foundation
import CoreFoundation

// =====================================================================
// MARK: - Window-server event intake
// =====================================================================

/// What a pending intake item is about. Events of one kind for one id
/// merge while they wait for the drain.
enum IntakeKind: UInt8, CaseIterable {
    case frame                   // 806 / 807
    case reordered               // 808
    case destroyed               // 804
    case spaceWindowCreated      // 1325
    case animationBegan          // 1327 (window callback)
    case frontmost               // 1508
    case spaces                  // 1327 / 1328 / 1401 / 1204 (spaces callback)
    case missionControlEntered   // 1204

    var name: String {
        switch self {
        case .frame:                 return "frame"
        case .reordered:             return "reordered"
        case .destroyed:             return "destroyed"
        case .spaceWindowCreated:    return "spaceWindowCreated"
        case .animationBegan:        return "animationBegan"
        case .frontmost:             return "frontmost"
        case .spaces:                return "spaces"
        case .missionControlEntered: return "missionControlEntered"
        }
    }
}

/// Merge key: a kind plus the wid it concerns (0 for process-wide kinds).
struct IntakeKey: Hashable {
    let kind: IntakeKind
    let id: UInt32
}

/// One merged pending entry. `payload` is the latest event offered under
/// `key`; `firstEnqueued` (uptime ns, nil when nothing is timing the
/// intake) and the entry's drain position are the first event's.
struct IntakeItem<Payload> {
    let key: IntakeKey
    var payload: Payload
    let firstEnqueued: UInt64?
    var count: Int
}

/// Pending events merged per key, in first-arrival order. Pure: the
/// caller owns locking and scheduling. `offer` returns true when the queue
/// was empty — exactly when a drain has to be scheduled, since `take`
/// empties it at the start of every drain.
struct IntakeQueue<Payload> {
    private var order: [IntakeKey] = []
    private var items: [IntakeKey: IntakeItem<Payload>] = [:]

    var isEmpty: Bool { order.isEmpty }
    var pendingCount: Int { order.count }

    mutating func offer(_ key: IntakeKey, _ payload: Payload, now: UInt64?) -> Bool {
        if var item = items[key] {
            item.payload = payload
            item.count += 1
            items[key] = item
            return false
        }
        let wasEmpty = order.isEmpty
        order.append(key)
        items[key] = IntakeItem(key: key, payload: payload, firstEnqueued: now, count: 1)
        return wasEmpty
    }

    mutating func take() -> [IntakeItem<Payload>] {
        let batch = order.compactMap { items[$0] }
        order.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
        return batch
    }
}

/// An event the window-server callbacks hand to the main thread.
enum IntakeEvent {
    case window(CGSDecodedWindowEvent)
    case spaces
    case missionControlEntered

    /// The merge key, nil for events with nothing to do on main.
    var key: IntakeKey? {
        switch self {
        case .spaces:                return IntakeKey(kind: .spaces, id: 0)
        case .missionControlEntered: return IntakeKey(kind: .missionControlEntered, id: 0)
        case .window(let e):
            switch e {
            case .moved(let wid), .resized(let wid):
                return IntakeKey(kind: .frame, id: wid)
            case .reordered(let wid):          return IntakeKey(kind: .reordered, id: wid)
            case .destroyed(let wid):          return IntakeKey(kind: .destroyed, id: wid)
            case .spaceWindowCreated(let wid, _):
                return IntakeKey(kind: .spaceWindowCreated, id: wid)
            case .animationBegan:              return IntakeKey(kind: .animationBegan, id: 0)
            case .frontmostByMouse:            return IntakeKey(kind: .frontmost, id: 0)
            case .titleChanged, .spaceWindowDestroyed, .ignored, .malformed:
                return nil
            }
        }
    }
}

/// The one hop from the window-server callbacks to main. SkyLight posts
/// a burst of events (a drag's 806s, a space switch's 1401 + 1325s) on
/// whatever thread services the connection; rather than one
/// DispatchQueue.main.async per event, events merge per (kind, wid) in
/// `IntakeQueue` and the whole burst drains in one block on the main run
/// loop. The block is queued with CFRunLoopPerformBlock in the common modes
/// (so it also runs during event tracking and live resize) and the run
/// loop is woken so it runs without waiting for another source.
enum WindowServerIntake {
    private static let lock = NSLock()
    private static var queue = IntakeQueue<IntakeEvent>()
    private static var stats = Stats()

    struct Stats {
        var offered = 0
        var merged = 0
        var drains = 0
        var maxBatch = 0
    }

    static func statsSnapshot() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Queue `event` for the next drain. Any thread.
    static func post(_ event: IntakeEvent) {
        guard let key = event.key else { return }
        lock.lock()
        let before = queue.pendingCount
        let schedule = queue.offer(key, event, now: nil)
        stats.offered += 1
        if queue.pendingCount == before { stats.merged += 1 }
        lock.unlock()
        guard schedule else { return }
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { drain() }
        CFRunLoopWakeUp(main)
    }

    private static func drain() {
        lock.lock()
        let batch = queue.take()
        stats.drains += 1
        stats.maxBatch = max(stats.maxBatch, batch.count)
        lock.unlock()
        for item in batch { handle(item.payload) }
    }

    private static func handle(_ event: IntakeEvent) {
        switch event {
        case .window(let e):
            WindowEvents.dispatch(e)
        case .spaces:
            SpacesObserver.shared.fire()
        case .missionControlEntered:
            AppDelegate.shared?.host?.bang(name: "sd.missionControl.entered", detail: [:])
        }
    }
}
