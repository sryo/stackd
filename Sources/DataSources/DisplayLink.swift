import Foundation
import CoreVideo
import CoreGraphics

// CVDisplayLink-driven push channel. Fires at the display's vsync rate
// (60 Hz standard, 120 Hz ProMotion) — cheaper + smoother than rAF inside
// a heavy WebView, and aligned to the compositor's flip cadence which is
// what sd.overlay's CG context flushes need to avoid tearing.
//
// Consumers:
//  - sd.overlay (planned) — needs vsync-aligned flush
//  - any Canvas-heavy stack that wants ProMotion-rate ticks without
//    fighting rAF throttling inside a backgrounded WebView

enum DisplayLink {
    /// Most-recent frame snapshot. Nil before the first vsync arrives.
    static func snapshot() -> [String: Any]? {
        DisplayLinkObserver.shared.snapshot()
    }
}

// Top-level C-convention callback. CVDisplayLinkOutputCallback's signature
// can't be satisfied by a Swift closure without going through a thunk; the
// refcon recovers the singleton without resorting to globals. Fires on a
// private CV thread — we update the snapshot under the lock then hop to
// main to call fire() so JS dispatch stays on one queue.
private func displayLinkCallback(
    _ link: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ displayLinkContext: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx = displayLinkContext else { return kCVReturnSuccess }
    let observer = Unmanaged<DisplayLinkObserver>.fromOpaque(ctx).takeUnretainedValue()

    // videoRefreshPeriod / videoTimeScale = seconds per refresh; invert for Hz.
    // Falls back to the configured nominal period if videoRefreshPeriod is
    // zero (some virtualized / mirrored configurations report 0 here).
    let out = inOutputTime.pointee
    let period = Double(out.videoRefreshPeriod)
    let scale = Double(out.videoTimeScale)
    let refreshRate: Double
    if period > 0 && scale > 0 {
        refreshRate = scale / period
    } else {
        let nominal = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        let nominalSeconds = Double(nominal.timeValue) / Double(nominal.timeScale)
        refreshRate = nominalSeconds > 0 ? 1.0 / nominalSeconds : 60.0
    }

    observer.acceptFrame(
        timestamp: CFAbsoluteTimeGetCurrent(),
        refreshRate: refreshRate
    )
    return kCVReturnSuccess
}

final class DisplayLinkObserver: RefCountedObserver {
    static let shared = DisplayLinkObserver()
    private override init() { super.init() }

    private var link: CVDisplayLink?
    private let lock = NSLock()
    private var current: (timestamp: Double, frame: Int, refreshRate: Double)?
    private var frameCounter: Int = 0

    // Keeps the singleton retained through Unmanaged.passRetained so the
    // displayLinkContext pointer is always valid for the lifetime of the
    // active link. Balanced by release() in teardown.
    private var refconRetainer: Unmanaged<DisplayLinkObserver>?

    func snapshot() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current else { return nil }
        return ["timestamp": c.timestamp, "frame": c.frame, "refreshRate": c.refreshRate]
    }

    /// Called from the CV thread. Bumps the frame counter, updates the
    /// snapshot under the lock, then hops to main to notify subscribers.
    func acceptFrame(timestamp: Double, refreshRate: Double) {
        lock.lock()
        frameCounter += 1
        current = (timestamp: timestamp, frame: frameCounter, refreshRate: refreshRate)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.fire() }
    }

    override func install() -> Token? {
        var newLink: CVDisplayLink?
        let createStatus = CVDisplayLinkCreateWithActiveCGDisplays(&newLink)
        guard createStatus == kCVReturnSuccess, let link = newLink else { return nil }

        let retained = Unmanaged.passRetained(self)
        self.refconRetainer = retained
        let refcon = retained.toOpaque()

        let cbStatus = CVDisplayLinkSetOutputCallback(link, displayLinkCallback, refcon)
        guard cbStatus == kCVReturnSuccess else {
            retained.release()
            self.refconRetainer = nil
            return nil
        }

        let startStatus = CVDisplayLinkStart(link)
        guard startStatus == kCVReturnSuccess else {
            _ = CVDisplayLinkSetOutputCallback(link, nil, nil)
            retained.release()
            self.refconRetainer = nil
            return nil
        }

        self.link = link

        return Token { [weak self] in self?.teardown() }
    }

    private func teardown() {
        if let link = link {
            // Order matters: Stop first to halt the callback queue, then clear
            // the callback so any in-flight invocation can't reach our refcon
            // after we release it. Swift ARC releases the CVDisplayLink ref
            // when `self.link` is nilled out.
            if CVDisplayLinkIsRunning(link) { _ = CVDisplayLinkStop(link) }
            _ = CVDisplayLinkSetOutputCallback(link, nil, nil)
        }
        link = nil

        if let retainer = refconRetainer {
            retainer.release()
            refconRetainer = nil
        }

        lock.lock()
        current = nil
        frameCounter = 0
        lock.unlock()
    }
}
