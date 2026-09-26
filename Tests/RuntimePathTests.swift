import Foundation

/// `runtimeCandidates` is the pure core of `runtimePath()` — given the dir
/// holding the executable, it returns the Runtime/ roots to probe in order.
/// Two layouts must both resolve: the dev build (Runtime symlinked next to
/// .build/stackd) and the packaged .app (Contents/Resources/Runtime).
func registerRuntimePathTests() {
    test("dev layout: Runtime next to the binary is probed first") {
        let exeDir = URL(fileURLWithPath: "/repo/.build")
        let got = runtimeCandidates(executableDir: exeDir)
        try expectEqual(got.first, "/repo/.build/Runtime")
    }

    test("bundle layout: next-to-binary first, then Contents/Resources/Runtime") {
        // Next-to-binary outranks Resources so a dev symlink wins.
        let exeDir = URL(fileURLWithPath: "/Applications/stackd.app/Contents/MacOS")
        try expectEqual(runtimeCandidates(executableDir: exeDir), [
            "/Applications/stackd.app/Contents/MacOS/Runtime",
            "/Applications/stackd.app/Contents/Resources/Runtime",
        ])
    }
}
