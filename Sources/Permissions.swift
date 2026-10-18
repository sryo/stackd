import Foundation

/// Every permission stackd vends, derived from what actually gates something:
/// the `permission:` of each `Bridge.primitives` entry, the `permission` of
/// each `Channels.all` entry, and the composite permissions below. Shipping a
/// primitive or channel under a new permission registers it here.
///
/// Consumers:
///
///   1. `StackDoctor.known` (Sources/StackTemplates.swift) — the allowlist
///      for `permissions:` entries in `stack.json`.
///
///   2. `ChannelInference.topLevelChannels` (Sources/StackSource.swift) —
///      the permissions auto-inferred from `sd.<perm>.` references in stack
///      source text (`inferable`).
///
/// `PermissionsRegistryTests` pins the shipped set so a permission can't
/// silently disappear with its last primitive; `RuntimeBridgeLinksTests`
/// checks each inferable permission is a real `sd.<perm>` namespace.
enum Permissions {
    /// Permissions that gate a write surface inside a base namespace (e.g.
    /// `menubar` covers the read path while `menubar.item` mutates the
    /// system menu bar). Authors must declare them explicitly so the surface
    /// stays visible at review; they are never inferred from source text.
    static let composite: Set<String> = ["menubar.item"]

    /// Every permission the daemon accepts.
    static let all: Set<String> = Bridge.primitivePermissions
        .union(Channels.all.map(\.permission))
        .union(composite)

    /// Subset of `all` that channel inference auto-adds from `sd.<perm>.`
    /// references in stack source.
    static let inferable: Set<String> = all.subtracting(composite)

    /// Deterministic-order list of `inferable` for the scanner. Sorted so
    /// iteration order is stable across runs — `ChannelInference.infer`
    /// returns a Set so ordering doesn't matter for the output, but a
    /// sorted list keeps the scan reproducible if anyone logs intermediate
    /// state.
    static let inferableSorted: [String] = inferable.sorted()
}
