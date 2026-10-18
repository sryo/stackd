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

/// Values waiting under keys, in first-arrival order. Offering a key that
/// already waits merges into the waiting value in place, so the key keeps
/// its position and one entry stands for every offer made since the last
/// `take`. Pure: the caller owns locking and scheduling.
struct LatestWinsQueue<Key: Hashable, Value> {
    private var order: [Key] = []
    private var values: [Key: Value] = [:]

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }

    func contains(_ key: Key) -> Bool { values[key] != nil }

    /// Queue `value` under `key`. A key already waiting gets
    /// `merge(waiting, value)` in its place instead. True when the key was
    /// new.
    @discardableResult
    mutating func offer(_ key: Key, _ value: Value, merge: (Value, Value) -> Value) -> Bool {
        if let waiting = values[key] {
            values[key] = merge(waiting, value)
            return false
        }
        order.append(key)
        values[key] = value
        return true
    }

    /// Everything waiting, first-arrival order; the queue is left empty.
    mutating func take() -> [(key: Key, value: Value)] {
        let batch = order.compactMap { key in values[key].map { (key: key, value: $0) } }
        order.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
        return batch
    }
}

/// Pending events merged per key, in first-arrival order. Pure: the
/// caller owns locking and scheduling. `offer` returns true when the queue
/// was empty — exactly when a drain has to be scheduled, since `take`
/// empties it at the start of every drain.
struct IntakeQueue<Payload> {
    private var queue = LatestWinsQueue<IntakeKey, IntakeItem<Payload>>()

    var isEmpty: Bool { queue.isEmpty }
    var pendingCount: Int { queue.count }

    mutating func offer(_ key: IntakeKey, _ payload: Payload, now: UInt64?) -> Bool {
        let wasEmpty = queue.isEmpty
        queue.offer(key, IntakeItem(key: key, payload: payload, firstEnqueued: now, count: 1)) {
            waiting, offered in
            IntakeItem(key: key, payload: offered.payload,
                       firstEnqueued: waiting.firstEnqueued,
                       count: waiting.count + offered.count)
        }
        return wasEmpty
    }

    mutating func take() -> [IntakeItem<Payload>] {
        queue.take().map { $0.value }
    }
}

/// One spaces pass per drain. A space switch posts 1401,
/// activeSpaceDidChange and often 1325s for windows already on the new
/// space; each used to cost its own Spaces.all() read on main. Requests
/// made while a drain runs collapse into one pass at its end; a request
/// outside a drain tells the caller to post a spaces event instead.
struct SpacesCoalescer {
    private var draining = false
    private var requested = false

    mutating func begin() {
        draining = true
        requested = false
    }

    /// True when the caller must post a spaces event (no drain running).
    mutating func request() -> Bool {
        if draining { requested = true; return false }
        return true
    }

    /// True when the drain owes one spaces pass.
    mutating func end() -> Bool {
        draining = false
        defer { requested = false }
        return requested
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
            case .titleChanged, .spaceWindowDestroyed, .probe, .ignored, .malformed:
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
    // Main thread.
    private static var spaces = SpacesCoalescer()
    private static let tracer = IntakeTracer(enabled: IntakeTrace.enabled,
                                             capacity: IntakeTrace.capacity)

    /// The trace so far (STACKD_TRACE=1). Main thread.
    static var traceRing: TraceRing<IntakeTraceRecord> { tracer.ring }

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
        let now = tracer.stamp()
        lock.lock()
        let before = queue.pendingCount
        let schedule = queue.offer(key, event, now: now)
        stats.offered += 1
        if queue.pendingCount == before { stats.merged += 1 }
        lock.unlock()
        guard schedule else { return }
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { drain() }
        CFRunLoopWakeUp(main)
    }

    /// Ask for a spaces refresh: folded into the running drain's one
    /// spaces pass, or posted when no drain is running. Main thread.
    static func requestSpaces() {
        if spaces.request() { post(.spaces) }
    }

    private static func drain() {
        lock.lock()
        let batch = queue.take()
        stats.drains += 1
        stats.maxBatch = max(stats.maxBatch, batch.count)
        lock.unlock()
        let drainStart = tracer.stamp()
        var spacesEnqueued: UInt64?
        var spacesMerged = 0
        spaces.begin()
        for item in batch {
            if item.key.kind == .spaces {
                spacesEnqueued = item.firstEnqueued
                spacesMerged = item.count
            }
            tracer.measure(item.key.kind, enqueued: item.firstEnqueued, merged: item.count) {
                handle(item.payload)
            }
        }
        // The pass's queue wait runs from the first queued spaces event, or
        // from the drain start when only a handler asked for it.
        if spaces.end() {
            tracer.measure(.spaces, enqueued: spacesEnqueued ?? drainStart,
                           merged: max(spacesMerged, 1)) {
                SpacesObserver.shared.fire()
            }
        }
    }

    private static func handle(_ event: IntakeEvent) {
        switch event {
        case .window(let e):
            WindowEvents.dispatch(e)
        case .spaces:
            requestSpaces()
        case .missionControlEntered:
            AppDelegate.shared?.host?.bang(name: "sd.missionControl.entered", detail: [:])
        }
    }
}
