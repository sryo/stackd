import AppKit

enum Appearance {
    static func current() -> [String: Any] {
        var isDark = false
        if let app = NSApp {
            isDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let r = Int(((accent?.redComponent   ?? 0) * 255).rounded())
        let g = Int(((accent?.greenComponent ?? 0) * 255).rounded())
        let b = Int(((accent?.blueComponent  ?? 0) * 255).rounded())
        return [
            "dark":         isDark,
            "accent":       ["r": r, "g": g, "b": b],
            "accentHex":    String(format: "#%02x%02x%02x", r, g, b),
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ]
    }
}

/// Light/dark + accent + reduce-motion. Push on:
///   - AppleInterfaceThemeChangedNotification (distributed) — dark/light flip
///   - NSWorkspace.accessibilityDisplayOptionsDidChangeNotification — reduce motion
///   - 2s poll — accent color (no notification exists for NSColor.controlAccentColor)
final class AppearanceObserver {
    static let shared = AppearanceObserver()

    private var subs: [() -> Void] = []
    private var pollTimer: Timer?

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.fire() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.fire() }

        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func subscribe(_ cb: @escaping () -> Void) { subs.append(cb) }
    func unsubscribeAll() { subs.removeAll() }
    private func fire() { for cb in subs { cb() } }
}
