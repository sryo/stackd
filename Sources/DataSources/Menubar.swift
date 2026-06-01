import AppKit
import ApplicationServices

// Four menu-related subsystems folded into one domain file:
//
//   - StatusItemHandle / Menubar  — NSStatusBar items (sd.menubar.addItem)
//   - MenuBarVisibility          — system menu-bar suppress/restore via
//                                  CGSSetMenuBarVisibility (sd.menubar.suppress)
//   - PopupMenu                  — transient cursor-position context menu
//                                  (sd.menu.popup)
//   - MenubarItems               — read-only enumeration of every visible
//                                  menu-bar status item (sd.menubar.items /
//                                  sd.menubar.observe). Ice-style AX walk.
//
// They share the AppKit menu surface but otherwise have distinct APIs and
// SPIs. Kept under one roof so stack authors thinking "I want menu stuff"
// open one file. Mirrors hs.menubar.*'s grouped shape.

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

// MARK: - System menu-bar visibility (sd.menubar.suppress / restore)

private enum SkyLightMenuBar {
    typealias SetMenuBarVisibilityFn = @convention(c) (Bool) -> Void
    static let setMenuBarVisibility: SetMenuBarVisibilityFn? = SkyLight.sym("CGSSetMenuBarVisibility")
}

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

// MARK: - Popup context menu at the cursor (sd.menu.popup)

/// Native NSMenu popup at the current cursor location. Builds an NSMenu from
/// a declarative spec (id/title/checked/enabled/separator/submenu) and resolves
/// with the id of whatever the user clicked, or null on cancel. Native because
/// a web modal can't escape the WebView's z-order, and a CSS "context menu"
/// doesn't get the system font / hit-testing / kbd nav.
enum PopupMenu {
    static func present(items: [[String: Any]], completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            let coordinator = Coordinator(completion: completion)
            let menu = build(items: items, coordinator: coordinator)
            coordinator.menu = menu

            // popUpMenu(positioning:atLocation:inView:) is the no-event-needed
            // path that works from a background process. nil view → screen coords.
            let loc = NSEvent.mouseLocation
            DispatchQueue.main.async {
                let chose = menu.popUp(positioning: nil, at: loc, in: nil)
                if !chose {
                    coordinator.fire(nil)
                }
                // Hold the coordinator alive long enough for action callbacks
                // to fire on the main runloop.
                _ = coordinator
            }
        }
    }

    private static func build(items: [[String: Any]], coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for spec in items {
            if (spec["separator"] as? Bool) == true {
                menu.addItem(.separator())
                continue
            }
            let title = spec["title"] as? String ?? ""
            let item = NSMenuItem(title: title, action: #selector(Coordinator.picked(_:)), keyEquivalent: "")
            item.target = coordinator
            item.representedObject = spec["id"] as? String
            if let checked = spec["checked"] as? Bool, checked { item.state = .on }
            if let enabled = spec["enabled"] as? Bool, !enabled { item.isEnabled = false }
            if let sub = spec["submenu"] as? [[String: Any]] {
                item.submenu = build(items: sub, coordinator: coordinator)
                item.action = nil
                item.target = nil
            }
            menu.addItem(item)
        }
        return menu
    }

    final class Coordinator: NSObject {
        let completion: (String?) -> Void
        var fired = false
        var menu: NSMenu?
        init(completion: @escaping (String?) -> Void) { self.completion = completion }

        func fire(_ id: String?) {
            guard !fired else { return }
            fired = true
            completion(id)
        }

        @objc func picked(_ sender: NSMenuItem) {
            fire(sender.representedObject as? String)
        }
    }
}

// MARK: - Menubar items (sd.menubar.items / sd.menubar.observe)

// Read-only enumeration of every visible status item in the system menubar.
// Walks the AX tree from the system-wide AXUIElement: each running app with
// status items exposes them as AXMenuBarItem children of an AXMenuBar.
// Ice (https://github.com/jordanbaird/Ice) proves this is doable without
// private API; we use the same path.
//
// macOS 14+ quirks:
//   - Apple's Control Center group (Wi-Fi / Bluetooth / AirDrop / Sound /
//     Focus / Screen Mirroring / etc.) lives in a separate AXSystemUIServer
//     process and is NOT enumerable via the standard menubar walk. We
//     surface third-party menubar items + Apple's Spotlight + clock; the
//     Control Center cluster is documented as a limitation rather than
//     special-cased.
//   - Items pushed past the system's chevron (notch-induced overflow on
//     MacBook Pro 14"/16", or just too many items for the bar width) live
//     off-screen at negative X or beyond the right edge. The hidden field
//     surfaces this so a menubar-manager UI can show "hidden" items
//     separately.
//
// Performance: the AX walk happens on every poll (2s default). NSRunning-
// Application lookup is the slow part of the per-item cost (per-PID dict
// walk inside AppKit); we cache resolved owner names by PID for the life
// of the observer to keep each tick cheap.

enum MenubarItems {
    /// Pure helper: classify whether a status-item rect falls outside the
    /// visible menubar. Items pushed past the system's chevron sit at
    /// negative X or beyond the screen's right edge. Tested directly.
    ///
    /// `screenLeft` and `screenRight` are the visible menubar's left and
    /// right X coordinates (screen frame in points, AX coordinate space).
    /// `itemX` is the item's left edge, `itemWidth` its width.
    static func isHidden(itemX: Double, itemWidth: Double, screenLeft: Double, screenRight: Double) -> Bool {
        // Past the chevron: item is entirely left of the screen's leftmost
        // pixel, or its left edge is past the right edge (no visible portion
        // remains). The chevron itself is a status item that the system
        // owns, so we don't have a precise "before the chevron" threshold —
        // off-screen is the only signal that's reliable cross-version.
        if itemX + itemWidth <= screenLeft { return true }
        if itemX >= screenRight            { return true }
        return false
    }

    /// Pure helper: resolve a PID to a human-readable owner name. Prefers
    /// the bundle identifier (stable, app-suite-aware), falls back to the
    /// localized process name, then to a "pid:NNNN" sentinel so callers
    /// always get a non-empty string. The `cache` dict is read-then-written
    /// to amortize NSRunningApplication's per-PID lookup across a poll cycle.
    /// Tested directly with an injected resolver to keep the helper pure.
    static func resolveOwner(pid: pid_t, cache: inout [pid_t: String],
                             resolver: (pid_t) -> (bundleId: String?, name: String?)?) -> String {
        if let hit = cache[pid] { return hit }
        let resolved = resolver(pid)
        let owner: String
        if let bid = resolved?.bundleId, !bid.isEmpty {
            owner = bid
        } else if let name = resolved?.name, !name.isEmpty {
            owner = name
        } else {
            owner = "pid:\(pid)"
        }
        cache[pid] = owner
        return owner
    }

    /// One-shot snapshot of every menubar status item visible to the AX
    /// tree. Returns one dict per item:
    ///   { owner: String, title: String, x: Double, width: Double, hidden: Bool }
    /// `owner` is the bundle identifier (or localized name) of the app that
    /// owns the item. `title` is the displayed text (empty for icon-only
    /// items — most apps). `x` is the absolute screen-X of the item's
    /// left edge, `width` its width in points. `hidden` flags items
    /// pushed past the system's chevron / off-screen.
    ///
    /// Requires Accessibility. Returns [] if not granted. macOS 14+
    /// Control Center cluster is NOT included — that lives in a separate
    /// AXSystemUIServer process not walkable from systemWide.
    static func items() -> [[String: Any]] {
        var cache: [pid_t: String] = [:]
        return items(ownerCache: &cache)
    }

    /// Internal entry-point that accepts an external cache. The observer
    /// keeps the cache alive across polls so NSRunningApplication lookups
    /// don't repeat for the same PID every tick.
    static func items(ownerCache: inout [pid_t: String]) -> [[String: Any]] {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)

        var menuBarRef: AnyObject?
        // kAXExtrasMenuBarAttribute carries the "status items" menubar
        // (right-hand side: clock, Spotlight, Control Center entry,
        // third-party icons). The vanilla kAXMenuBarAttribute on the
        // system-wide element returns the active app's app-menubar
        // (Apple/File/Edit/...) which is NOT what we want here.
        let extrasErr = AXUIElementCopyAttributeValue(
            systemWide, "AXExtrasMenuBar" as CFString, &menuBarRef
        )
        guard extrasErr == .success, let menuBar = menuBarRef else {
            // Accessibility denied or the extras attribute isn't exposed
            // (rare; older macOS). Empty array beats throwing — stacks see
            // "no items" and can render the empty state.
            return []
        }
        let menuBarEl = menuBar as! AXUIElement
        AXUIElementSetMessagingTimeout(menuBarEl, 0.5)

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBarEl, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return []
        }

        // Visible menubar bounds. Use the main screen's frame in AX
        // coordinate space (top-left origin, same as AXPosition values).
        // Items past the screen's left/right edges are flagged hidden.
        let screen = NSScreen.main
        let screenLeft  = Double(screen?.frame.minX ?? 0)
        let screenRight = Double(screen?.frame.maxX ?? 1)

        var out: [[String: Any]] = []
        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.1)

            // Owner: AXUIElementGetPid returns the PID of the app that
            // created the status item (third-party app, SystemUIServer for
            // Apple-owned items like Spotlight / clock).
            var pid: pid_t = 0
            guard AXUIElementGetPid(child, &pid) == .success else { continue }
            let owner = resolveOwner(pid: pid, cache: &ownerCache) { p in
                guard let app = NSRunningApplication(processIdentifier: p) else { return nil }
                return (app.bundleIdentifier, app.localizedName)
            }

            let title = axStringAttr(child, kAXTitleAttribute as String) ?? ""
            let position = axPointAttr(child, kAXPositionAttribute as String) ?? .zero
            let size     = axSizeAttr(child,  kAXSizeAttribute     as String) ?? .zero
            let x        = Double(position.x)
            let width    = Double(size.width)
            let hidden   = isHidden(itemX: x, itemWidth: width,
                                    screenLeft: screenLeft, screenRight: screenRight)

            out.append([
                "owner":  owner,
                "title":  title,
                "x":      x,
                "width":  width,
                "hidden": hidden
            ])
        }
        // Sort by x — gives JS consumers a left-to-right order that matches
        // what the user sees in the menubar.
        out.sort { (Double(($0["x"] as? Double) ?? 0)) < (Double(($1["x"] as? Double) ?? 0)) }
        return out
    }

    // MARK: - AX attribute helpers (file-local)

    private static func axStringAttr(_ el: AXUIElement, _ key: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func axPointAttr(_ el: AXUIElement, _ key: String) -> CGPoint? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success,
              let value = ref else { return nil }
        let axVal = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axVal, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSizeAttr(_ el: AXUIElement, _ key: String) -> CGSize? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success,
              let value = ref else { return nil }
        let axVal = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axVal, .cgSize, &size) else { return nil }
        return size
    }
}

/// 2s poll for menubar items. AX has no push notification for status-item
/// add/remove (the AXLayoutChanged / AXCreated events fire only for window-
/// scoped trees), so we pull on a timer and let `startChannel`'s dedupe
/// suppress unchanged ticks. Tunable per-stack via `sd.channel.setInterval`
/// (`sd.menubar.observe.subscribe(fn, { interval: 10 })`); the native poll
/// itself stays at 2s because other subscribers may want it.
///
/// Per the file-header notes: NSRunningApplication lookups are the slow
/// part of each tick. Owner cache lives on the observer so successive polls
/// don't repeat the per-PID walk for steady-state items (third-party
/// menubar icons don't change PID across their app's lifetime).
final class MenubarItemsObserver: RefCountedObserver {
    static let shared = MenubarItemsObserver()
    private override init() { super.init() }

    /// Owner-name cache keyed by PID. Reset when an app quits (the PID
    /// drops from the AX tree on its own; we don't proactively prune
    /// because stale entries are harmless — they're overwritten the next
    /// time the same PID is reused, which is rare).
    fileprivate var ownerCache: [pid_t: String] = [:]

    /// Snapshot used by Bridge.startMenubarItems. Calls items() with the
    /// shared cache so repeated polls stay cheap.
    func snapshot() -> [[String: Any]] {
        MenubarItems.items(ownerCache: &ownerCache)
    }

    override func install() -> Token {
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(t, forMode: .common)
        return Token { t.invalidate() }
    }
}
