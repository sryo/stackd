import Foundation

/// Canonical list of every permission stackd vends.
///
/// Before this consolidation, three parallel hardcoded lists drifted apart
/// when a primitive landed without all three being touched:
///
///   1. `StackDoctor.known` (Sources/StackTemplates.swift) — the allowlist
///      for `permissions:` entries in `stack.json`. Drift here means the
///      doctor warns "unknown permission — typo?" on legitimate stacks.
///
///   2. `ChannelInference.topLevelChannels` (Sources/StackSource.swift) —
///      the set of permissions auto-inferred from `sd.<perm>.` references
///      in stack source text. Drift here means a stack mentioning `sd.foo`
///      doesn't get the `foo` permission auto-added.
///
///   3. `Bridge.primitives` (Sources/Bridge.swift) — each `.sync(...)`,
///      `.custom(...)`, `.ax(...)`, `.syncBridge(...)` registration carries
///      a `permission:` gate string. There was no central enumeration —
///      the source of truth was buried in the registrations themselves.
///
/// Drift caught after this refactor landed: `bluetooth`, `disks`, `hotkey`,
/// `urlhandler` (vended by `Bridge.primitives` but missing from the doctor
/// allowlist), and `sensors` (auto-inferred but missing from the doctor
/// allowlist). All consolidated into `Permissions.all` below.
///
/// Same-commit guard: `PermissionsRegistryTests` walks `Bridge.primitivePermissions`
/// and asserts every entry is in `Permissions.all`. Ship a new primitive
/// with permission "foo" → test fails until "foo" is added here.
///
/// Mirrors the `Channels` registry pattern (Sources/Channels.swift) — one
/// place to edit, downstream consumers derive automatically.
enum Permissions {
    /// Every permission the daemon accepts. Includes channel-vending
    /// permissions (subset that also appears in `Channels.all`), RPC-only
    /// namespaces, and composite permissions that gate specific side-effect
    /// surfaces within a base namespace.
    ///
    /// When shipping a new `sd.X` primitive: add `"X"` here. `StackDoctor`
    /// and `ChannelInference` both derive from this set, so no other file
    /// needs touching. `PermissionsRegistryTests` fails CI if you forget.
    static let all: Set<String> = [
        // --- Channel-vending permissions (also in Channels.all) -----------
        "battery", "mouse", "appearance", "caffeinate",
        "sensors", "location", "usb", "camera", "touchdevice", "displayLink",
        "app", "windows", "input", "net", "audio", "display", "media",
        "pasteboard", "apps", "spaces", "host", "calendar", "menubar",
        "privacy",

        // --- Pure RPC namespaces (no signal channel; identity-named) ------
        "fs", "proc", "applescript", "notify", "settings", "defaults",
        "broadcasts", "ax", "spotlight", "speech", "vision", "nlp",
        "bonjour", "httpserver", "sqlite", "update", "cursor", "overlay",
        "shortcuts", "sound", "icons", "thumbnails", "events", "menu",
        "bluetooth", "disks", "hotkey", "urlhandler", "symbol",

        // --- Composite permissions (don't auto-infer; explicit only) ------
        // Composites carry stricter side-effects than their base namespace
        // (e.g. `menubar.observe` is read-only; `menubar.item` mutates the
        // system menu bar). Authors must opt in explicitly so the surface
        // stays visible at review.
        "menubar.item",
    ]

    /// Subset of `all` that channel-inference SHOULD auto-add from
    /// `sd.<perm>.` references in stack source. Composite permissions
    /// (`menubar.item`) are excluded — they require explicit declaration
    /// regardless of source-text mentions, because the base namespace
    /// (`menubar`) covers the read path while the composite is a write
    /// surface.
    static let inferable: Set<String> = all.subtracting(["menubar.item"])

    /// Deterministic-order list of `inferable` for the scanner. Sorted so
    /// iteration order is stable across runs — `ChannelInference.infer`
    /// returns a Set so ordering doesn't matter for the output, but a
    /// sorted list keeps the scan reproducible if anyone logs intermediate
    /// state.
    static let inferableSorted: [String] = inferable.sorted()
}
