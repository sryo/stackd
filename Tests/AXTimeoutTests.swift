import AppKit
import ApplicationServices

// An element read out of another one does not inherit its messaging timeout:
// a window taken from an app element capped at 0.1s still waits the system
// default (1.5s or more) when its app stops answering. These tests stop a
// real process (this binary relaunched with --ax-victim) after deriving its
// elements, then time a read on them. They need Accessibility trust and an
// AX server that answers; where either is missing they return without
// asserting, the capability-gate pattern WindowsTests uses.

/// A titled panel AppKit leaves where it is put, so the victim's window can
/// sit off every screen, or hang mostly off one. It reads as a dialog, so
/// window managers (windowscape, sd.windows.all) leave it alone.
private final class VictimPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

/// A title bar accessory nested ten accessibility groups deep, past the hit
/// walk's limit, the way a web-drawn title bar (Electron) buries its parts.
private func deepTitlebarAccessory() -> NSTitlebarAccessoryViewController {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
    var parent = root
    for _ in 0..<10 {
        let child = NSView(frame: parent.bounds)
        child.autoresizingMask = [.width, .height]
        child.setAccessibilityElement(true)
        child.setAccessibilityRole(.group)
        parent.addSubview(child)
        parent = child
    }
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = root
    accessory.layoutAttribute = .right
    return accessory
}

/// The relaunched test binary's whole life when asked to be the victim: one
/// titled 400x300 panel (close button, title bar with an 80pt-wide deep
/// accessory at its right end, content), until killed.
/// `--ax-victim` puts it off every screen; `--ax-victim <x> <y>` puts its
/// top-left corner at that global (top-left origin) point.
func runAXVictimIfAsked() {
    let args = CommandLine.arguments
    guard let flag = args.firstIndex(of: "--ax-victim") else { return }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = VictimPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
    var topLeft = CGPoint(x: -4000, y: 4000)
    if args.count > flag + 2, let x = Double(args[flag + 1]), let y = Double(args[flag + 2]) {
        topLeft = CGPoint(x: x, y: y)
    }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    panel.addTitlebarAccessoryViewController(deepTitlebarAccessory())
    panel.animationBehavior = .none
    panel.setFrameTopLeftPoint(NSPoint(x: topLeft.x, y: primaryHeight - topLeft.y))
    panel.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
    app.run()
    exit(0)
}

/// Launches the victim (off every screen, or with its top-left corner at
/// `topLeft`) and waits for its window, then hands `body` the pid and a
/// `freeze` that SIGSTOPs it. Returns without calling `body` when the
/// environment can't deliver a window.
func withAXVictim(at topLeft: CGPoint? = nil, _ body: (pid_t, () -> Void) throws -> Void) throws {
    guard AXIsProcessTrusted(), let exe = Bundle.main.executableURL else { return }
    let process = Process()
    process.executableURL = exe
    process.arguments = ["--ax-victim"] + (topLeft.map { ["\($0.x)", "\($0.y)"] } ?? [])
    try process.run()
    let pid = process.processIdentifier
    defer {
        kill(pid, SIGKILL)
        process.waitUntilExit()
    }
    let appEl = AX.appElement(pid: pid, timeout: 0.5)
    guard spin(timeout: 10, until: { !AX.children(of: appEl, timeout: 0.5).isEmpty }) else { return }
    try body(pid) { kill(pid, SIGSTOP) }
}

private func elapsed(_ work: () -> Void) -> TimeInterval {
    let start = Date()
    work()
    return Date().timeIntervalSince(start)
}

func registerAXTimeoutTests() {
    test("AX.elements(of:timeout:) caps the elements it returns") {
        try withAXVictim { pid, freeze in
            let appEl = AX.appElement(pid: pid, timeout: 0.1)
            guard let win = AX.elements(of: appEl, kAXWindowsAttribute, timeout: 0.1)?.first else {
                throw Expectation(message: "victim has no window")
            }
            freeze()
            let took = elapsed { _ = AX.string(of: win, kAXRoleAttribute) }
            try expect(took < 0.5, "derived window read took \(took)s on a stopped app")
        }
    }

    test("AX.element(of:timeout:) caps the element it returns") {
        try withAXVictim { pid, freeze in
            let appEl = AX.appElement(pid: pid, timeout: 0.1)
            guard let win = AX.children(of: appEl, timeout: 0.1).first,
                  let parent = AX.element(of: win, kAXParentAttribute, timeout: 0.1) else {
                throw Expectation(message: "victim window has no parent")
            }
            freeze()
            let took = elapsed { _ = AX.string(of: parent, kAXRoleAttribute) }
            try expect(took < 0.5, "derived parent read took \(took)s on a stopped app")
        }
    }

    test("sd.ax handles minted from another element read within the handle cap") {
        try withAXVictim { pid, freeze in
            let store = AX.HandleStore()
            let app = AX.application(pid: pid, store: store)
            guard let win = AX.children(handle: app, store: store)?.first else {
                throw Expectation(message: "victim has no child handle")
            }
            freeze()
            let took = elapsed { _ = AX.attribute(handle: win, name: kAXRoleAttribute, store: store) }
            try expect(took < 1.0, "minted handle read took \(took)s on a stopped app")
        }
    }
}
