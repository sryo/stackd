import AppKit

// Everything that touches the system menu bar:
//
//   MenuBarVisibility — refcounted suppress/restore of the whole macOS menu
//     bar via CGSSetMenuBarVisibility (SkyLight private SPI).
//
//   StatusItemHandle / Menubar.addItem — NSStatusItem wrapper backing
//     sd.menubar.addItem. Each stack mints zero or more items; the handle
//     adopts a Token into the stack's StackScope so unload removes the icon.
//
// PopupMenu (sd.menu.popup) lives in Menu.swift — it's a transient cursor
// menu, not part of the system menu bar.

// MARK: - SkyLight CGSSetMenuBarVisibility (shared loader in Sources/Private/SkyLight.swift)

private enum SkyLightMenuBar {
    typealias SetMenuBarVisibilityFn = @convention(c) (Bool) -> Void
    static let setMenuBarVisibility: SetMenuBarVisibilityFn? = SkyLight.sym("CGSSetMenuBarVisibility")
}

// MARK: - Refcounted system menu bar visibility

/// Reference-counted system menu-bar visibility. Multiple stacks can suppress;
/// the menu bar reappears only when every suppressor has called restore().
enum MenuBarVisibility {
    private static let lock = NSLock()
    private static var suppressorCount = 0

    /// Each suppress() returns a Token whose cancel decrements the refcount.
    /// Stacks adopt the Token into their scope so unload always pairs with
    /// suppression — no more leaks if a stack dies between suppress/restore.
    /// Returns nil if SkyLight failed to load.
    static func suppress() -> Token? {
        guard let fn = SkyLightMenuBar.setMenuBarVisibility else { return nil }
        lock.lock()
        suppressorCount += 1
        if suppressorCount == 1 { fn(false) }
        lock.unlock()
        var released = false
        return Token {
            lock.lock(); defer { lock.unlock() }
            // Guard against double-cancel (adopt + explicit cancel).
            guard !released else { return }
            released = true
            suppressorCount = max(0, suppressorCount - 1)
            if suppressorCount == 0 { fn(true) }
        }
    }

    /// Called on daemon shutdown / reload so we never leak the menu bar hidden.
    static func resetForReload() {
        guard let fn = SkyLightMenuBar.setMenuBarVisibility else { return }
        lock.lock(); defer { lock.unlock() }
        if suppressorCount > 0 {
            suppressorCount = 0
            fn(true)
        }
    }

    /// Called once at daemon startup. If a previous daemon died with the menu
    /// bar suppressed (kill -9, crash, power loss), inherit a known-good state
    /// rather than the user's stale "menubar hidden" surprise.
    static func forceRestoreOnLaunch() {
        let handleOK = SkyLight.handle != nil
        let symOK    = SkyLightMenuBar.setMenuBarVisibility != nil
        FileHandle.standardError.write(Data("stackd: SkyLight handle=\(handleOK) sym=\(symOK)\n".utf8))
        guard let fn = SkyLightMenuBar.setMenuBarVisibility else { return }
        lock.lock(); defer { lock.unlock() }
        suppressorCount = 0
        fn(true)
    }
}

// MARK: - NSStatusItem (sd.menubar.addItem)

// Each stack mints zero or more items; the item handle adopts a Token into
// the stack's StackScope so unload (or daemon-shutdown) always removes the
// icon from the menu bar. All UI mutation must run on main — the Bridge
// dispatcher hops to main before calling these.

struct StatusItemSpec {
    var icon: IconSpec?
    var title: String?
    var menu: [[String: Any]]?
    var tooltip: String?
}

struct IconSpec {
    var sfSymbol: String?
    var pngBase64: String?
    /// Defaults to true. SF Symbols always render template; raw PNGs you
    /// might want full color (e.g. an app icon) — caller can opt out.
    var template: Bool = true
}

/// One running NSStatusItem plus the wiring to fire JS callbacks on click
/// and menu picks. The Bridge owns these in a per-stack id → handle map.
final class StatusItemHandle {
    let item: NSStatusItem
    let id: Int
    /// Called when the user clicks the status item and no menu is set.
    var onClick: (() -> Void)?
    /// Called with the picked menu-item id when a menu pick resolves.
    var onMenuPick: ((String) -> Void)?

    private var actionTarget: ActionTarget?
    private var menuDelegate: MenuPickDelegate?

    init(id: Int, spec: StatusItemSpec) {
        self.id = id
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyIcon(spec.icon)
        applyTitle(spec.title)
        applyTooltip(spec.tooltip)
        applyMenu(spec.menu)
        // If no menu was set, wire click → onClick. If a menu WAS set, the
        // wiring happens lazily on setMenu(nil) — see installActionTargetIfNeeded.
        if spec.menu == nil {
            installActionTargetIfNeeded()
        }
    }

    /// NSStatusItem.button click handler. Idempotent — only installs once.
    /// Called both at init (no-menu mode) and from applyMenu(nil) when a
    /// menu-mode item drops back to click mode.
    private func installActionTargetIfNeeded() {
        guard actionTarget == nil, let button = item.button else { return }
        let target = ActionTarget { [weak self] in self?.onClick?() }
        button.target = target
        button.action = #selector(ActionTarget.fire)
        self.actionTarget = target
    }

    func setTitle(_ s: String?)        { applyTitle(s) }
    func setIcon(_ icon: IconSpec?)    { applyIcon(icon) }
    func setMenu(_ items: [[String: Any]]?) { applyMenu(items) }
    func setTooltip(_ s: String?)      { applyTooltip(s) }

    func remove() {
        // Idempotent — removing a removed status item is a no-op in AppKit
        // but we still clear our refs so a Token's cancel doesn't double-fire.
        NSStatusBar.system.removeStatusItem(item)
    }

    private func applyTitle(_ s: String?) {
        item.button?.title = s ?? ""
    }

    private func applyTooltip(_ s: String?) {
        item.button?.toolTip = s
    }

    private func applyIcon(_ spec: IconSpec?) {
        guard let spec = spec else { item.button?.image = nil; return }
        if let sym = spec.sfSymbol,
           let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
            img.isTemplate = spec.template
            item.button?.image = img
            return
        }
        if let b64 = spec.pngBase64,
           let data = Data(base64Encoded: b64),
           let img = NSImage(data: data) {
            img.isTemplate = spec.template
            item.button?.image = img
            return
        }
        item.button?.image = nil
    }

    private func applyMenu(_ items: [[String: Any]]?) {
        guard let items = items else {
            // Drop menu mode → restore click mode. Without this lazy install,
            // a status item created with a menu would become dead on click
            // when setMenu(null) was called (button.target was never set).
            item.menu = nil
            menuDelegate = nil
            installActionTargetIfNeeded()
            return
        }
        let menu = NSMenu()
        let delegate = MenuPickDelegate { [weak self] id in self?.onMenuPick?(id) }
        menu.delegate = delegate
        for entry in items {
            menu.addItem(StatusItemHandle.buildItem(entry, picker: delegate))
        }
        item.menu = menu
        // Setting item.menu disconnects the button-click path; AppKit drives
        // menu open on click automatically.
        self.menuDelegate = delegate
    }

    private static func buildItem(_ entry: [String: Any], picker: MenuPickDelegate) -> NSMenuItem {
        if (entry["separator"] as? Bool) == true {
            return NSMenuItem.separator()
        }
        let title = entry["title"] as? String ?? ""
        let mi = NSMenuItem(title: title, action: #selector(MenuPickDelegate.fire(_:)), keyEquivalent: "")
        mi.target = picker
        if let entryId = entry["id"] as? String { mi.representedObject = entryId }
        if let enabled = entry["enabled"] as? Bool { mi.isEnabled = enabled }
        if let checked = entry["checked"] as? Bool { mi.state = checked ? .on : .off }
        if let submenu = entry["submenu"] as? [[String: Any]] {
            let sub = NSMenu(title: title)
            sub.delegate = picker
            for e in submenu { sub.addItem(buildItem(e, picker: picker)) }
            mi.submenu = sub
        }
        return mi
    }
}

/// NSStatusItem.button target/action wrapper. AppKit insists on an @objc
/// target — closures don't satisfy it, so we wrap one.
private final class ActionTarget: NSObject {
    let onFire: () -> Void
    init(_ onFire: @escaping () -> Void) { self.onFire = onFire }
    @objc func fire() { onFire() }
}

/// NSMenuItem target — picks the `representedObject` (the JS-side id) and
/// passes it back through the JS callback. Also serves as menu delegate to
/// hold the strong reference (NSMenu has weak `delegate`).
private final class MenuPickDelegate: NSObject, NSMenuDelegate {
    let onPick: (String) -> Void
    init(_ onPick: @escaping (String) -> Void) { self.onPick = onPick }
    @objc func fire(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onPick(id)
    }
}

enum Menubar {
    /// Creates the status item and returns the handle. Caller is expected to
    /// wire `handle.onClick` / `handle.onMenuPick` immediately after.
    static func addItem(id: Int, spec: StatusItemSpec) -> StatusItemHandle {
        StatusItemHandle(id: id, spec: spec)
    }
}
