import Carbon
import Foundation

// `input.isSecureInputEnabled` (hs.eventtap.isSecureInputEnabled): whether
// macOS is withholding keyboard events from event taps because a password
// field or another secure-input client holds the keyboard. Asked through
// the real bridge, as a stack's `sd.input.isSecureInputEnabled()` would.
func registerSecureInputTests() {
    test("input.isSecureInputEnabled answers the system's secure-input state") {
        let page = try BridgedPage()
        try page.start(permissions: ["input"])
        let expected = IsSecureEventInputEnabled() ? "true" : "false"
        let got = page.answer(requestId: 31, #"{type: "input.isSecureInputEnabled", requestId: 31}"#)
        try expectEqual(got, expected)
    }

    test("input.isSecureInputEnabled answers false to a stack without the input permission") {
        let page = try BridgedPage()
        try expectEqual(page.answer(requestId: 32, #"{type: "input.isSecureInputEnabled", requestId: 32}"#), "false")
    }
}
