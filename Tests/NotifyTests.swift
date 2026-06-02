import Foundation

// Tests for Sources/DataSources/Notify.swift.
//
// Coverage reality: Notify.swift is ~50 lines with exactly two members —
//   1. `static func show(title:body:subtitle:sound:) -> Bool`
//      Spawns `/usr/bin/osascript -e 'display notification ...'`. Calling
//      it from the test harness would emit a real banner attributed to
//      Script Editor on every test run — observable side effect, not a
//      pure helper.
//   2. `private static func escape(_:) -> String`
//      AppleScript string-literal escaper (backslash + double-quote).
//      Private, so unreachable from this file without changing production
//      visibility — which the test brief forbids.
//
// What's *not* in Notify.swift, despite what a generic "notifications"
// module might suggest: no spec validation, no identifier dedup, no
// action-button parsing, no image-attachment path normalization, no
// default-value substitution. The Bridge dispatcher (Bridge.swift:760)
// applies `??""` fallbacks for title/body and passes subtitle/sound as
// raw Optionals — that's all the "validation" the surface has, and it
// lives in Bridge, not Notify.
//
// The mirror of this file in MenubarItemsTests / CameraStreamTests works
// because those modules each factored pure primitives (`isHidden`,
// `resolveOwner`, `clampedFps`, `normalizedFormat`) out for exactly this
// purpose. Notify never grew that layer because there was no logic worth
// extracting — quoting one string is the entire job.
//
// If/when Notify gains real parse logic (UNUserNotificationCenter v2 with
// action buttons + identifier registry, per the file's header comment),
// this file is where those tests land. For now we register a single
// existence assertion so the file isn't an empty no-op in the harness.

func registerNotifyTests() {
    test("Notify.show is reachable as a static member with the documented signature") {
        // Compile-time witness: if the symbol's signature drifts, this
        // file stops building and the harness flags it. We never invoke
        // the function — doing so would spawn osascript and emit a real
        // banner notification on the developer's desktop.
        let _: (String, String, String?, String?) -> Bool = Notify.show
        try expect(true)
    }
}
