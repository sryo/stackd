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

    test("bundle layout: Contents/Resources/Runtime is a candidate") {
        let exeDir = URL(fileURLWithPath: "/Applications/stackd.app/Contents/MacOS")
        let got = runtimeCandidates(executableDir: exeDir)
        try expect(got.contains("/Applications/stackd.app/Contents/Resources/Runtime"),
                   "Resources/Runtime must be probed for the .app layout; got \(got)")
    }

    test("next-to-binary outranks Resources so a dev symlink wins") {
        let exeDir = URL(fileURLWithPath: "/Applications/stackd.app/Contents/MacOS")
        let got = runtimeCandidates(executableDir: exeDir)
        let nextTo = got.firstIndex(of: "/Applications/stackd.app/Contents/MacOS/Runtime")
        let resources = got.firstIndex(of: "/Applications/stackd.app/Contents/Resources/Runtime")
        try expect(nextTo != nil && resources != nil && nextTo! < resources!,
                   "next-to-binary must precede Resources; got \(got)")
    }
}
