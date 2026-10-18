import Foundation

/// `HandleTable` — the per-stack tables of native handles a primitive mints
/// an id for and hands to JS (hotkeys, DN observers, servers, streams, ...).
func registerHandleTableTests() {
    /// A Token that counts its cancels into `log[name]`.
    final class CancelLog { var counts: [String: Int] = [:] }
    func token(_ name: String, _ log: CancelLog) -> Token {
        Token { log.counts[name, default: 0] += 1 }
    }

    test("HandleTable: minted ids are unique and never reused after a removal") {
        let log = CancelLog()
        let table = HandleTable<Token>()
        let a = table.insert(token("a", log))
        let b = table.insert(token("b", log))
        let c = table.insert(token("c", log))
        try expectEqual(Set([a, b, c]).count, 3)
        try expect(table.cancel(b))
        let d = table.insert(token("d", log))
        try expect(![a, b, c].contains(d), "id \(d) reused")
    }

    test("HandleTable: cancel(id) cancels that token once and forgets it") {
        let log = CancelLog()
        let table = HandleTable<Token>()
        let a = table.insert(token("a", log))
        let b = table.insert(token("b", log))
        try expect(table.cancel(b))
        try expectEqual(log.counts, ["b": 1])
        try expect(!table.cancel(b), "second cancel of the same id")
        try expect(!table.cancel(999), "unknown id")
        try expectEqual(log.counts, ["b": 1])
        try expect(table[a] != nil && table[b] == nil)
    }

    test("HandleTable: cancelAll cancels every remaining token exactly once and empties the table") {
        let log = CancelLog()
        let table = HandleTable<Token>()
        _ = table.insert(token("a", log))
        let b = table.insert(token("b", log))
        _ = table.insert(token("c", log))
        try expect(table.cancel(b))
        table.cancelAll()
        try expectEqual(log.counts, ["a": 1, "b": 1, "c": 1])
        try expect(table.isEmpty)
        table.cancelAll()
        try expectEqual(log.counts, ["a": 1, "b": 1, "c": 1])
    }

    test("HandleTable: a token whose cancel touches the table during cancelAll is safe") {
        // Stream handles remove themselves from their table when they end,
        // which stopping them can trigger synchronously.
        let table = HandleTable<Token>()
        var ids: [Int] = []
        var cancels = 0
        for _ in 0..<3 {
            ids.append(table.insert(Token {
                cancels += 1
                for id in ids { _ = table.remove(id) }
            }))
        }
        table.cancelAll()
        try expectEqual(cancels, 3)
        try expect(table.isEmpty)
    }

    test("HandleTable: mintId reserves an id that a later store fills") {
        let table = HandleTable<String>()
        let id = table.mintId()
        try expect(table[id] == nil)
        table[id] = "late"
        try expectEqual(table[id], "late")
        try expect(table.insert("next") != id)
        try expectEqual(table.remove(id), "late")
        try expectEqual(table.remove(id), nil)
    }

    test("HandleTable: drain returns every value and empties the table") {
        let table = HandleTable<String>()
        _ = table.insert("a")
        _ = table.insert("b")
        try expectEqual(table.drain().sorted(), ["a", "b"])
        try expect(table.isEmpty)
        try expectEqual(table.drain(), [])
    }

    test("handles: a minted handle is released once by its primitive, and unload drains the rest") {
        let page = try BridgedPage()
        try page.start(permissions: ["broadcasts"])
        func observe(_ rid: Int) -> String? {
            page.answer(requestId: rid, #"{type: "broadcasts.observe", name: "com.stackd.tests.never", requestId: \#(rid)}"#)
        }
        func unobserve(_ rid: Int, _ id: Int) -> String? {
            page.answer(requestId: rid, #"{type: "broadcasts.unobserve", id: \#(id), requestId: \#(rid)}"#)
        }
        try expectEqual(observe(21), "1")
        try expectEqual(observe(22), "2")
        try expectEqual(unobserve(23, 1), "true")
        try expectEqual(unobserve(24, 1), "false")
        try expectEqual(observe(25), "3")
        page.bridge.scope.drain()
        try expect(page.bridge.broadcastTokens.isEmpty, "unload left broadcast observers registered")
        try expectEqual(unobserve(26, 2), "false")
    }

    test("HandleTable: tables sharing HandleIds never hand out the same id") {
        let ids = HandleIds()
        let servers = HandleTable<String>(ids: ids)
        let requests = HandleTable<Int>(ids: ids)
        let s1 = servers.insert("s1")
        let r1 = requests.insert(1)
        let s2 = servers.mintId()
        try expectEqual(Set([s1, r1, s2]).count, 3)
        try expectEqual([s1, r1, s2], [1, 2, 3])
    }
}
