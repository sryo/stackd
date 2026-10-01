import Foundation

/// Stack management primitives — the in-stack face of `stackd list`,
/// `stackd disable` and `stackd enable`:
///
///   - `stacks.list` → { loaded: [id], disabled: [id] }
///   - `stacks.disable` / `stacks.enable` { id } → { ok, error? }
///
/// Disable unloads the stack and parks its folder in <root>/disabled/, so it
/// stays off across reloads; enable moves it back and loads it. Both run on
/// a later main-queue turn: a stack may disable itself, and its Bridge must
/// not be torn down inside its own message handler.
extension Bridge {
    static func stacksPrimitives() -> [Primitive] {
        return [
            .custom("stacks.list", permission: "stacks") { bridge, _, requestId in
                DispatchQueue.main.async { [weak bridge] in
                    let host = AppDelegate.shared?.host
                    bridge?.respond(requestId: requestId, value: [
                        "loaded":   host?.loadedStackIds() ?? [],
                        "disabled": host?.disabledStackIds() ?? [],
                    ])
                }
            },
            .custom("stacks.disable", permission: "stacks") { bridge, body, requestId in
                let id = body["id"] as? String ?? ""
                DispatchQueue.main.async { [weak bridge] in
                    let error = AppDelegate.shared?.host?.disable(id: id) ?? "host not ready"
                    bridge?.respond(requestId: requestId, value: Bridge.stacksResult(error))
                }
            },
            .custom("stacks.enable", permission: "stacks") { bridge, body, requestId in
                let id = body["id"] as? String ?? ""
                DispatchQueue.main.async { [weak bridge] in
                    let error = AppDelegate.shared?.host?.enable(id: id) ?? "host not ready"
                    bridge?.respond(requestId: requestId, value: Bridge.stacksResult(error))
                }
            },
        ]
    }

    private static func stacksResult(_ error: String?) -> [String: Any] {
        error.map { ["ok": false, "error": $0] } ?? ["ok": true]
    }
}
