import Foundation

// FocusedReadSchedule (Sources/DataSources/Windows.swift): when the
// frontmost app's focused window is read off main after an activation or an
// AX focus notification. Latest wins per pid, one read in flight per pid, a
// read for an app that is no longer the target is dropped, and a read that
// finds no window yet gets one delayed retry.

func registerFocusedReadScheduleTests() {
    test("FocusedReadSchedule: the first request starts a read") {
        var s = FocusedReadSchedule()
        try expect(s.request(pid: 100))
        try expect(s.awaiting)
    }

    test("FocusedReadSchedule: a found window is delivered and clears awaiting") {
        var s = FocusedReadSchedule()
        _ = s.request(pid: 100)
        try expectEqual(s.resolved(pid: 100, found: true), .deliver)
        try expect(!s.awaiting)
    }

    test("FocusedReadSchedule: a request during a read coalesces into one re-read") {
        var s = FocusedReadSchedule()
        try expect(s.request(pid: 100))
        try expect(!s.request(pid: 100))
        try expect(!s.request(pid: 100))
        try expectEqual(s.resolved(pid: 100, found: true), .readAgain)
        try expect(s.awaiting)
        try expectEqual(s.resolved(pid: 100, found: true), .deliver)
    }

    test("FocusedReadSchedule: a read for an app that lost the target is discarded") {
        var s = FocusedReadSchedule()
        _ = s.request(pid: 100)
        try expect(s.request(pid: 200))  // other app: its own read runs now
        try expectEqual(s.resolved(pid: 100, found: true), .discard)
        try expect(s.awaiting)
        try expectEqual(s.resolved(pid: 200, found: true), .deliver)
    }

    test("FocusedReadSchedule: a nil read retries once after the fallback delay") {
        var s = FocusedReadSchedule()
        _ = s.request(pid: 100)
        guard case .retry(let delay, let token) = s.resolved(pid: 100, found: false) else {
            throw Expectation(message: "expected a retry")
        }
        try expectEqual(delay, FocusedReadSchedule.nilRetryDelay)
        try expect(s.awaiting)
        try expect(s.retryDue(pid: 100, token: token))
        try expectEqual(s.resolved(pid: 100, found: false), .deliver)
        try expect(!s.awaiting)
    }

    test("FocusedReadSchedule: a fresh request supersedes a scheduled retry") {
        var s = FocusedReadSchedule()
        _ = s.request(pid: 100)
        guard case .retry(_, let stale) = s.resolved(pid: 100, found: false) else {
            throw Expectation(message: "expected a retry")
        }
        try expect(s.request(pid: 100))
        try expect(!s.retryDue(pid: 100, token: stale))
        try expectEqual(s.resolved(pid: 100, found: true), .deliver)
    }

    test("FocusedReadSchedule: a retry for an app that lost the target does not run") {
        var s = FocusedReadSchedule()
        _ = s.request(pid: 100)
        guard case .retry(_, let token) = s.resolved(pid: 100, found: false) else {
            throw Expectation(message: "expected a retry")
        }
        _ = s.request(pid: 200)
        try expect(!s.retryDue(pid: 100, token: token))
    }

    test("FocusedReadSchedule: reset forgets everything") {
        var s = FocusedReadSchedule()
        _ = s.request(pid: 100)
        s.reset()
        try expect(!s.awaiting)
        try expectEqual(s.resolved(pid: 100, found: true), .discard)
        try expect(s.request(pid: 100))
    }
}
