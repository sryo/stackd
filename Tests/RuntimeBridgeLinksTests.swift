import Foundation

/// Drift guard for the permission → `sd.<perm>` joint: channel inference
/// grants a permission when a stack's source mentions `sd.<perm>.`, so every
/// inferable permission that gates a channel or primitive must exist as a
/// namespace on the `sd` object the runtime builds. (The request `type:` ↔
/// dispatch-key joint is guarded by the `surface:` wire-type tests.)
func registerRuntimeBridgeLinksTests() {
    test("links: every inferable namespace permission exists as sd.<perm> in the runtime") {
        let namespaces = Bridge.primitivePermissions.union(Channels.all.map(\.permission))
        let perms = Permissions.inferable.intersection(namespaces).sorted()
        try expect(!perms.isEmpty, "no inferable namespace permissions found")
        let list = perms.map { "\"\($0)\"" }.joined(separator: ",")
        let missing = JSHarness.evalString("""
        [\(list)].filter(function(p){
          var v = sd[p];
          return v == null || (typeof v !== "object" && typeof v !== "function");
        }).join(",")
        """)
        try expectEqual(missing, "", "inferable permissions with no sd.<perm> namespace")
    }
}
