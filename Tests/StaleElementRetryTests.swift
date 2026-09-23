import Foundation
import ApplicationServices

// Tests for `StaleElementRetry` in `Sources/DataSources/Windows.swift` — a
// cached AXUIElement can die (sleep/wake, app AX server restart) while its
// window lives on. A read that fails as invalid/unanswered must re-resolve
// the element once before the addressability probe records a verdict,
// instead of caching isStandard:false against a dead element forever.

func registerStaleElementRetryTests() {
    test("StaleElementRetry re-resolves once on an invalid element") {
        try expect(StaleElementRetry.shouldReResolve(readError: .invalidUIElement, attempt: 0))
        try expect(StaleElementRetry.shouldReResolve(readError: .cannotComplete, attempt: 0))
    }

    test("StaleElementRetry keeps a successful read") {
        try expect(!StaleElementRetry.shouldReResolve(readError: .success, attempt: 0))
    }

    test("StaleElementRetry gives up after one re-resolve") {
        try expect(!StaleElementRetry.shouldReResolve(readError: .invalidUIElement, attempt: 1))
    }

    test("StaleElementRetry doesn't retry answers that are real (attribute unsupported)") {
        try expect(!StaleElementRetry.shouldReResolve(readError: .attributeUnsupported, attempt: 0))
        try expect(!StaleElementRetry.shouldReResolve(readError: .noValue, attempt: 0))
    }
}
