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
final class AppearanceObserver: RefCountedObserver {
    static let shared = AppearanceObserver()
    private override init() { super.init() }

    override func install() -> Token {
        let ncToken = installNotifications([
            (DistributedNotificationCenter.default(),
             NSNotification.Name("AppleInterfaceThemeChangedNotification")),
            (NSWorkspace.shared.notificationCenter,
             NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        ])

        // Accent color has no system notification; poll while observer is
        // active. The whole timer stops once the last subscriber leaves.
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(timer, forMode: .common)

        return Token {
            ncToken.cancel()
            timer.invalidate()
        }
    }
}
