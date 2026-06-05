import Foundation

/// AX primitive group — extracted from Bridge.swift as part of the
/// god-object breakup continuation (follow-up to A1+A4+A5). Eighteen
/// `.ax` entries covering the per-Bridge AXUIElement surface:
///
///   - Discovery — `ax.focused`, `ax.application`, `ax.system`,
///     `ax.systemElementAtPosition`, `ax.focusedElement`,
///     `ax.focusedElementSystemWide`. The unhandled four mint
///     `AX.HandleStore` entries (per-Bridge ownership so a stack reload
///     doesn't strand handles); `ax.focused` is a one-shot snapshot.
///
///   - Attribute reads — `ax.attributeNames`, `ax.attribute`,
///     `ax.attributes`, `ax.parameterizedAttributeNames`,
///     `ax.parameterizedAttribute`. Each looks up a stored handle by id
///     and walks the AX tree from there.
///
///   - Action/mutation — `ax.actionNames`, `ax.isAttributeSettable`,
///     `ax.setAttribute`, `ax.performAction`. The two write verbs
///     deny → false so a denied permission can't accidentally appear
///     successful.
///
///   - Tree walk — `ax.children`, `ax.parent`, `ax.role`. Direct
///     accessors so JS-side AX traversal doesn't have to round-trip
///     through `ax.attribute("AXChildren")` etc.
///
///   - Handle lifecycle — `ax.release` / `ax.releaseAll`. Both
///     intentionally have NO permission gate (`permission: nil`):
///     releasing a handle is always safe regardless of the original
///     "ax" permission state, so a stack that lost the permission via
///     manifest edit can still drop refs.
///
/// `axHandles` was widened from private to internal in Bridge.swift so
/// this file's `.ax` closures can mint and release handles via the
/// per-Bridge `AX.HandleStore`. The deinit + scope drain on Bridge.swift
/// already calls `axHandles.releaseAll()` so this file doesn't need its
/// own teardown wiring.
///
/// All entries are `.ax` (main-hop) because AX queries deadlock or
/// silently partial-apply when invoked from a non-main thread — same
/// constraint that put `windows.byId.*` and `apps.menu` behind `.ax`.
extension Bridge {
    /// AX primitives — concatenated into `Bridge.primitives` alongside
    /// the rest of the inline registrations. Pure builder; no side effects.
    static func axPrimitives() -> [Primitive] {
        return [
            // Accessibility — all .ax variants hop to main and have access to axHandles via bridge
            .ax("ax.focused") { _, _ in AX.focusedElement() },
            .ax("ax.application")             { b, body in AX.application(pid: pid_t((body["pid"] as? Int) ?? 0), store: b.axHandles) },
            .ax("ax.system")                  { b, _    in AX.systemWide(store: b.axHandles) },
            .ax("ax.systemElementAtPosition") { b, body in AX.systemElementAtPosition(x: Float((body["x"] as? Double) ?? 0), y: Float((body["y"] as? Double) ?? 0), store: b.axHandles) },
            .ax("ax.focusedElement")          { b, _    in AX.focusedElementHandle(store: b.axHandles) },
            .ax("ax.focusedElementSystemWide"){ b, _    in AX.focusedElementSystemWideHandle(store: b.axHandles) },
            .ax("ax.attributeNames")          { b, body in AX.attributeNames(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
            .ax("ax.attribute")               { b, body in AX.attribute(handle: (body["handle"] as? Int) ?? -1, name: body["name"] as? String ?? "", store: b.axHandles) },
            .ax("ax.attributes")              { b, body in AX.attributes(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
            .ax("ax.parameterizedAttributeNames") { b, body in AX.parameterizedAttributeNames(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
            .ax("ax.parameterizedAttribute")  { b, body in AX.parameterizedAttribute(handle: (body["handle"] as? Int) ?? -1, name: body["name"] as? String ?? "", param: body["param"], store: b.axHandles) },
            .ax("ax.actionNames")             { b, body in AX.actionNames(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
            .ax("ax.isAttributeSettable")     { b, body in AX.isAttributeSettable(handle: (body["handle"] as? Int) ?? -1, name: body["name"] as? String ?? "", store: b.axHandles) },
            .ax("ax.setAttribute", denyValue: false) { b, body in AX.setAttribute(handle: (body["handle"] as? Int) ?? -1, name: body["name"] as? String ?? "", value: body["value"], store: b.axHandles) },
            .ax("ax.performAction", denyValue: false) { b, body in AX.performAction(handle: (body["handle"] as? Int) ?? -1, action: body["action"] as? String ?? "", store: b.axHandles) },
            .ax("ax.children")                { b, body in AX.children(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
            .ax("ax.parent")                  { b, body in AX.parent(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
            .ax("ax.role")                    { b, body in AX.role(handle: (body["handle"] as? Int) ?? -1, store: b.axHandles) },
            // release / releaseAll have no permission gate — releasing a handle is
            // always safe regardless of the original "ax" permission state.
            .ax("ax.release",    permission: nil) { b, body in b.axHandles.release((body["handle"] as? Int) ?? -1) },
            .ax("ax.releaseAll", permission: nil) { b, _    in b.axHandles.releaseAll(); return true },
        ]
    }
}
