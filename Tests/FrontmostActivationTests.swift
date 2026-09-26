import Foundation

// FrontmostActivation (Sources/DataSources/Windows.swift): the dedupe
// between the two activation triggers. CGS 1508 names the new frontmost pid
// a few ms before NSWorkspace's didActivateApplication for the same switch;
// whichever lands first runs the activation path, the other is a no-op.

func registerFrontmostActivationTests() {
    test("FrontmostActivation: a new pid activates") {
        var a = FrontmostActivation()
        try expect(a.shouldActivate(pid: 100))
    }

    test("FrontmostActivation: the second trigger for the same switch is dropped") {
        var a = FrontmostActivation()
        try expect(a.shouldActivate(pid: 100))   // 1508
        try expect(!a.shouldActivate(pid: 100))  // didActivateApplication
    }

    test("FrontmostActivation: switching away and back activates each time") {
        var a = FrontmostActivation()
        try expect(a.shouldActivate(pid: 100))
        try expect(a.shouldActivate(pid: 200))
        try expect(a.shouldActivate(pid: 100))
    }

    test("FrontmostActivation: seeded with the current frontmost app, re-reporting it is a no-op") {
        var a = FrontmostActivation()
        a.reset(to: 100)
        try expect(!a.shouldActivate(pid: 100))
        try expect(a.shouldActivate(pid: 200))
    }

    test("FrontmostActivation: reset to nil forgets the last pid") {
        var a = FrontmostActivation()
        _ = a.shouldActivate(pid: 100)
        a.reset(to: nil)
        try expect(a.shouldActivate(pid: 100))
    }
}
