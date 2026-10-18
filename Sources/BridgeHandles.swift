import Foundation

/// Mints the ids a stack's JS uses to name native handles: 1, 2, 3, ...,
/// never reused. Tables that share one never hand out the same id.
final class HandleIds {
    private var next = 1

    func mint() -> Int {
        defer { next += 1 }
        return next
    }
}

/// Native resources one stack holds through a primitive (Carbon hotkeys,
/// DN observers, servers, streams, ...), keyed by the id JS gets back.
/// Main-thread confined like the primitives that use it.
///
/// Values leave the table before any cancel runs, so a handle whose
/// teardown re-enters the table (a stream removing itself when it ends)
/// sees a consistent table.
final class HandleTable<Value> {
    private var entries: [Int: Value] = [:]
    private let ids: HandleIds

    init(ids: HandleIds = HandleIds()) { self.ids = ids }

    /// Reserves an id before the resource exists, for callbacks that must
    /// capture it; store the value later with `table[id] = value`.
    func mintId() -> Int { ids.mint() }

    /// Stores `value` under a fresh id and returns the id.
    @discardableResult
    func insert(_ value: Value) -> Int {
        let id = ids.mint()
        entries[id] = value
        return id
    }

    subscript(id: Int) -> Value? {
        get { entries[id] }
        set { entries[id] = newValue }
    }

    @discardableResult
    func remove(_ id: Int) -> Value? { entries.removeValue(forKey: id) }

    /// Empties the table and returns what it held.
    func drain() -> [Value] {
        let values = Array(entries.values)
        entries.removeAll()
        return values
    }

    var isEmpty: Bool { entries.isEmpty }
}

extension HandleTable where Value == Token {
    /// Cancels and forgets `id`'s token; false for an unknown id.
    @discardableResult
    func cancel(_ id: Int) -> Bool {
        guard let token = remove(id) else { return false }
        token.cancel()
        return true
    }

    func cancelAll() {
        for token in drain() { token.cancel() }
    }
}
